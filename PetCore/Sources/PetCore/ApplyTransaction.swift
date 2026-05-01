import Foundation
import GRDB

public final class ApplyTransaction {
    private let db: DatabaseQueue
    private let applier: EventApplier
    private let paused: Bool

    public init(db: DatabaseQueue, applier: EventApplier, paused: Bool) {
        self.db = db
        self.applier = applier
        self.paused = paused
    }

    public func process(jsonLine: String) throws {
        let event = try Event.parse(jsonLine)

        try db.write { conn in
            var pet = try aliveOrThrow(in: conn)

            do {
                try conn.execute(sql: """
                    INSERT INTO event (helper_event_id, ts, type, pet_id, payload)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [
                    event.eventId,
                    event.ts,
                    event.type.rawValue,
                    pet.id!,
                    jsonLine
                ])
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                return
            }

            let date = localDate(fromUnixMs: event.ts)
            try DailyRollup.upsert(
                eventDate: date, type: event.type,
                tokensIn: event.tokensIn ?? 0,
                tokensOut: event.tokensOut ?? 0,
                tool: event.tool, in: conn
            )

            if !paused {
                pet = applier.apply(event: event, to: pet)
                try pet.update(conn)
            }

            let eventDbId = try Int64.fetchOne(conn, sql: "SELECT MAX(id) FROM event")!
            try conn.execute(
                sql: "UPDATE pet SET last_applied_event_id = ? WHERE id = ?",
                arguments: [eventDbId, pet.id!]
            )
        }
    }

    private func aliveOrThrow(in conn: GRDB.Database) throws -> Pet {
        guard let p = try Pet.filter(Column("death_at") == nil).fetchOne(conn) else {
            throw ApplyTransactionError.noAlivePet
        }
        return p
    }

    private func localDate(fromUnixMs ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}

public enum ApplyTransactionError: Error {
    case noAlivePet
}
