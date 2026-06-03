import Foundation
import GRDB
import PetCore

@MainActor
final class PetPanelModel: ObservableObject {
    @Published private(set) var visual: PetVisual?
    @Published private(set) var species: String = ""
    @Published private(set) var fullness: Double = 0
    @Published private(set) var stamina: Double = 0
    @Published private(set) var intimacy: Double = 0
    @Published private(set) var level: Int = 0
    @Published private(set) var xpToNext: Int64 = 0
    @Published private(set) var todayTokens: Int64 = 0
    @Published private(set) var todaySessions: Int = 0
    @Published private(set) var todayTools: Int = 0
    @Published private(set) var activity: String = "空闲"
    @Published private(set) var hasPet: Bool = false

    private let db: DatabaseQueue
    private let config: ConfigYAML
    private let sessionWindowMs: Int64
    private var observer: NSObjectProtocol?

    init(db: DatabaseQueue, config: ConfigYAML, sessionWindowMs: Int64 = 15 * 60 * 1000) {
        self.db = db
        self.config = config
        self.sessionWindowMs = sessionWindowMs
        observer = NotificationCenter.default.addObserver(
            forName: .claudegotchiPetDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let pet = try? Pet.fetchAlive(from: db) else {
            hasPet = false
            return
        }
        hasPet = true
        species = pet.species
        fullness = pet.fullness
        stamina = pet.stamina
        intimacy = pet.intimacy

        let lv = Level.compute(xp: pet.xp)
        level = lv
        xpToNext = Int64(max(0, Level.xpForLevel(lv + 1) - pet.xp))

        let dayKey = LocalDay.key(unixMs: nowMs, timeZone: .current)
        let rollup = try? db.read { conn in try DailyRollup.fetch(date: dayKey, from: conn) }
        if let rollup = rollup ?? nil {
            todayTokens = Int64(rollup.tokensIn + rollup.tokensOut)
            todaySessions = rollup.sessions
            todayTools = rollup.toolsUsed
        } else {
            todayTokens = 0
            todaySessions = 0
            todayTools = 0
        }

        let sessions = activeSessions(nowMs: nowMs)
        let recent = sessions.max(by: { $0.lastActivityMs < $1.lastActivityMs })

        let tier = WorkPressure.tier((try? PRStore.allPRs(in: db)) ?? [], config: config)
        visual = PetMood.derive(pet: pet, pressure: tier)

        if pet.hibernationSince != nil {
            activity = "💤 休眠中"
        } else if let tool = recent?.lastTool {
            activity = "Claude 正在 \(tool)…"
        } else {
            activity = "空闲"
        }
    }

    func handlePetClick() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let pet = try? Pet.fetchAlive(from: db), let petId = pet.id else { return }
        let last = try? PetClickGate.lastClickMs(db)
        let cooldown = config.thresholds.petClickCooldownSeconds
        guard PetClick.allowed(lastClickMs: last ?? nil, nowMs: nowMs, cooldownSeconds: cooldown) else { return }

        let event = Event(
            schemaVersion: 1,
            eventId: "click:\(petId):\(nowMs)",
            ts: nowMs,
            type: .petClick,
            sessionId: nil,
            tool: nil,
            tokensIn: nil,
            tokensOut: nil,
            model: nil
        )
        let applier = EventApplier(config: config)
        try? ApplyTransaction(db: db, applier: applier, paused: false).process(event: event)
        postPetDidChange()
        refresh()
    }

    private func activeSessions(nowMs: Int64) -> [ActiveSession] {
        let repoPaths = (try? PRStore.watchedRepos(in: db))?
            .compactMap { repo -> (slug: String, path: String)? in
                guard let path = repo.localPath, !path.isEmpty else { return nil }
                return (slug: repo.slug, path: path)
            } ?? []
        return (try? SessionTracker.activeSessions(
            db: db, nowMs: nowMs, windowMs: sessionWindowMs, repoPaths: repoPaths
        )) ?? []
    }
}
