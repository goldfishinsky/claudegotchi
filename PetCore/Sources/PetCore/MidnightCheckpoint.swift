import Foundation
import GRDB

/// The once-per-local-day death-window driver (spec §7/§15 P3). Pure day-key
/// math plus a single DB transaction that appends today's low/healthy verdict
/// to the alive pet's death window and kills it when the window is full.
/// The App owns the timer that calls `runCheckpoint` on each day rollover;
/// `localDayKey`/`shouldRun` make that gating testable without a clock.
public enum MidnightCheckpoint {
    public struct Result: Equatable {
        public let ran: Bool
        public let died: Bool
        public init(ran: Bool, died: Bool) {
            self.ran = ran
            self.died = died
        }
    }

    public static func localDayKey(unixMs: Int64, timeZone: TimeZone) -> Int {
        let offsetMs = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000.0))) * 1000
        return Int((unixMs + offsetMs) / 86_400_000)
    }

    public static func shouldRun(lastCheckpointDay: Int?, nowMs: Int64,
                                 timeZone: TimeZone = .current) -> Bool {
        guard let last = lastCheckpointDay else { return true }
        return localDayKey(unixMs: nowMs, timeZone: timeZone) > last
    }

    @discardableResult
    public static func runCheckpoint(db: DatabaseQueue, config: ConfigYAML, nowMs: Int64) throws -> Result {
        try db.write { conn in
            guard var pet = try Pet.filter(Column("death_at") == nil).fetchOne(conn) else {
                return Result(ran: false, died: false)
            }

            let low = DeathWindow.isLowDay(
                pet: pet,
                threshold: config.thresholds.deathStatLow,
                requiredCount: config.thresholds.deathLowStatsRequired
            )
            pet = DeathWindow.appendDay(pet: pet, lowToday: low)
            try pet.update(conn)

            if DeathWindow.shouldDie(pet: pet) {
                try conn.execute(
                    sql: "UPDATE pet SET death_at = ? WHERE id = ?",
                    arguments: [nowMs, pet.id!]
                )
                return Result(ran: true, died: true)
            }
            return Result(ran: true, died: false)
        }
    }
}
