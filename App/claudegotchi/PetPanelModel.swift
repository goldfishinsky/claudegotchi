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

    // Theater inputs, refreshed alongside the vitals; the theater clock itself
    // runs per-frame client-side. Ages are stamped against `nowMs` at read time.
    private var workingCount = 0
    private var lastTokenStopMs: Int64?
    private var lastTokenStopTokens: Int64 = 0
    private var lastPrEventMs: Int64?
    private var lastClickMs: Int64?
    private var lastEventMs: Int64?
    private var hungry = false
    private var isSick = false
    private var isHibernating = false

    var systemMemPressure: (@MainActor () -> MemPressureTier?)?

    private let db: DatabaseQueue
    private let config: ConfigYAML
    private let sessionWindowMs: Int64
    private var observer: NSObjectProtocol?

    init(db: DatabaseQueue, config: ConfigYAML, sessionWindowMs: Int64 = 15 * 60 * 1000) {
        self.db = db
        self.config = config
        self.sessionWindowMs = sessionWindowMs
        observer = NotificationCenter.default.addObserver(
            forName: .claudegotchiPetDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
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
        let base = PetMood.derive(pet: pet, pressure: tier)

        workingCount = sessions.filter {
            $0.lastActivityMs >= nowMs - AgentActivityTracker.workingWindowMs
        }.count
        let tokenStop = try? TheaterQueries.latestTokenStop(db, sinceMs: nowMs - PetTheater.eatWindowMs)
        lastTokenStopMs = (tokenStop ?? nil)?.ts
        lastTokenStopTokens = (tokenStop ?? nil)?.tokens ?? 0
        lastPrEventMs = (try? TheaterQueries.latestPRCelebrationMs(db, sinceMs: nowMs - 120_000)) ?? nil
        lastClickMs = (try? TheaterQueries.latestClickMs(db)) ?? nil
        lastEventMs = (try? TheaterQueries.latestEventMs(db)) ?? nil
        hungry = pet.fullness < 30
        isSick = base.animation == .sick
        isHibernating = pet.hibernationSince != nil
        if let mem = systemMemPressure?() {
            visual = PetVisual(
                stage: base.stage, animation: base.animation,
                overlay: SystemMood.combine(base: base.overlay, mem: mem)
            )
        } else {
            visual = base
        }

        if pet.hibernationSince != nil {
            activity = "💤 休眠中"
        } else if let tool = recent?.lastTool {
            activity = "Claude 正在 \(tool)…"
        } else {
            activity = "空闲"
        }
    }

    func makeSignals(memPressureHigh: Bool) -> TheaterSignals {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let drop = lastTokenStopMs.map { TokenDrop(tokens: lastTokenStopTokens, ageMs: nowMs - $0) }
        let idleSeconds = lastEventMs.map { Double(max(0, nowMs - $0)) / 1000 } ?? .greatestFiniteMagnitude
        return TheaterSignals(
            workingAgentCount: workingCount,
            recentTokenDrop: drop,
            prCelebration: lastPrEventMs != nil,
            idleSeconds: idleSeconds,
            hibernating: isHibernating,
            sick: isSick,
            hungry: hungry,
            memPressureHigh: memPressureHigh,
            recentClickAgeMs: lastClickMs.map { nowMs - $0 }
        )
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
