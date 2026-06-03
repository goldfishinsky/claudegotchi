import Foundation
import GRDB
import PetCore

/// App-side once-per-local-day driver for the death-window checkpoint
/// (spec §7/§15 P3). A coarse timer wakes periodically; the pure
/// `MidnightCheckpoint.shouldRun` gate ensures the checkpoint runs at most
/// once per local day even if the machine slept across several days.
/// Reuses the App's single shared `DatabaseQueue` (§3 shared-instance
/// invariant) — it never opens its own.
@MainActor
final class MidnightDriver {
    private nonisolated let db: DatabaseQueue
    private nonisolated let config: ConfigYAML
    private nonisolated let onDeath: () -> Void

    private let lastDayKey = "claudegotchi.midnight.lastCheckpointDay"
    private var timer: Timer?

    init(db: DatabaseQueue, config: ConfigYAML, onDeath: @escaping () -> Void = {}) {
        self.db = db
        self.config = config
        self.onDeath = onDeath
    }

    func start() {
        runIfDue()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runIfDue() }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var storedLastDay: Int? {
        let v = UserDefaults.standard.object(forKey: lastDayKey) as? Int
        return v
    }

    private func runIfDue() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard MidnightCheckpoint.shouldRun(lastCheckpointDay: storedLastDay, nowMs: nowMs) else { return }

        let result = (try? MidnightCheckpoint.runCheckpoint(db: db, config: config, nowMs: nowMs))
            ?? MidnightCheckpoint.Result(ran: false, died: false)

        if result.ran {
            UserDefaults.standard.set(MidnightCheckpoint.localDayKey(unixMs: nowMs, timeZone: .current), forKey: lastDayKey)
        }
        if result.died { onDeath() }
    }
}
