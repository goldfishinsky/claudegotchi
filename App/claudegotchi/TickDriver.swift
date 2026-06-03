import Foundation
import GRDB
import PetCore

@MainActor
final class TickDriver {
    private nonisolated let db: DatabaseQueue
    private nonisolated let applier: EventApplier
    private nonisolated let config: ConfigYAML
    private nonisolated let pausedProvider: () -> Bool
    private nonisolated let nowMsProvider: () -> Int64
    private var timer: Timer?

    init(
        db: DatabaseQueue,
        applier: EventApplier,
        config: ConfigYAML,
        pausedProvider: @escaping () -> Bool,
        nowMsProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.db = db
        self.applier = applier
        self.config = config
        self.pausedProvider = pausedProvider
        self.nowMsProvider = nowMsProvider
    }

    func start() {
        tick()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let nowMs = nowMsProvider()
        guard let pet = try? Pet.fetchAlive(from: db), let petId = pet.id else { return }

        if pausedProvider() {
            var reanchored = pet
            reanchored.lastTickAt = nowMs
            try? Pet.update(reanchored, in: db)
            postPetDidChange()
            return
        }

        let result = TickCheckpoint.run(
            pet: pet, nowMs: nowMs, lastEventMs: pet.lastEventAt, config: config
        )
        try? Pet.update(result.pet, in: db)

        if let emit = result.emit {
            let type: Event.EventType = (emit == .hibernateStart) ? .hibernateStart : .hibernateEnd
            let event = Event(
                schemaVersion: 1,
                eventId: "tick:\(petId):\(emit.rawValue):\(nowMs)",
                ts: nowMs,
                type: type,
                sessionId: nil,
                tool: nil,
                tokensIn: nil,
                tokensOut: nil,
                model: nil
            )
            try? ApplyTransaction(db: db, applier: applier, paused: false).process(event: event)
        }

        postPetDidChange()
    }
}
