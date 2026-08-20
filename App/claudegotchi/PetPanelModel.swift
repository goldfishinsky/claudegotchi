import Foundation
import GRDB
import PetCore

@MainActor
final class PetPanelModel: ObservableObject {
    @Published private(set) var visual: PetVisual?
    @Published private(set) var species: String = ""
    @Published private(set) var look: PetLook = .base
    private var lastLookKey: String?
    @Published private(set) var fullness: Double = 0
    @Published private(set) var stamina: Double = 0
    @Published private(set) var intimacy: Double = 0
    @Published private(set) var level: Int = 0
    @Published private(set) var xpToNext: Int64 = 0
    @Published private(set) var todayTokens: Int64 = 0
    @Published private(set) var activity: String = "空闲"
    @Published private(set) var isAgentWorking = false
    @Published private(set) var activePlatforms: [String] = []
    @Published private(set) var hasPet: Bool = false

    // Theater inputs, refreshed alongside the vitals; the theater clock itself
    // runs per-frame client-side. Ages are stamped against `nowMs` at read time.
    private var workingCount = 0
    private var lastTokenStopMs: Int64?
    private var lastTokenStopTokens: Int64 = 0
    private var lastPrEventMs: Int64?
    private var lastTaskCompletionMs: Int64?
    private var completionDetector = CompletionDetector()
    private var lastClickMs: Int64?
    private var lastEventMs: Int64?
    private var hungry = false
    private var hungrySinceMs: Int64?
    private var lastPettingAccrualMs: Int64?
    private var isSick = false
    private var isHibernating = false
    private var recentTool: String?
    private var workingDurationSeconds: Double = 0
    private var permissionPending = false

    // One shared brain drives the island, dropdown and floating surfaces. It is
    // intentionally not @Published: frame rendering reads it, while only actual
    // pet/model changes invalidate SwiftUI.
    private var behaviorBrain = PetBehaviorBrain()
    private var behaviorEnvironment = PetEnvironment()
    private var behaviorProfile = PetBehaviorProfile()
    private var behaviorSeed: UInt64 = 0
    private var behaviorProfileKey: String?

    private static let hungryFullness = 30.0
    private static let intimacyHighThreshold = 80.0

    var systemMemPressure: (@MainActor () -> MemPressureTier?)?
    var systemThermal: (@MainActor () -> ThermalTier?)?
    var theaterSound: ((SceneFrame, Int64) -> Void)?

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
        if let petID = pet.id {
            let key = "claudegotchi.behaviorProfile.\(petID)"
            if behaviorProfileKey != key {
                behaviorProfileKey = key
                behaviorProfile = Self.loadBehaviorProfile(key: key)
                behaviorBrain.reset()
            }
        }
        behaviorSeed = pet.genome.map(UInt64.init(bitPattern:))
            ?? GenomeRNG.fnv1a64("\(pet.species):\(pet.id ?? 0)")
        let lookKey = "\(pet.genome.map(String.init) ?? "nil"):\(pet.species)"
        if lookKey != lastLookKey {
            look = PetLook.make(genome: pet.genome, species: pet.species)
            lastLookKey = lookKey
        }
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
        } else {
            todayTokens = 0
        }

        let sessions = activeSessions(nowMs: nowMs)
        let workingSessions = sessions.filter {
            $0.backgroundTasks > 0
                || $0.lastActivityMs >= nowMs - AgentActivityTracker.workingWindowMs
        }
        let recent = workingSessions.max(by: { $0.lastActivityMs < $1.lastActivityMs })
        let longest = sessions.map { Double(max(0, nowMs - $0.startedAtMs)) / 1000 }.max() ?? 0

        let tier = WorkPressure.tier((try? PRStore.allPRs(in: db)) ?? [], config: config)
        let base = PetMood.derive(pet: pet, pressure: tier)

        workingCount = workingSessions.count
        isAgentWorking = !workingSessions.isEmpty
        activePlatforms = Array(Set(workingSessions.map(\.platform))).sorted {
            if $0 == ModelPlatform.claudeCode { return true }
            if $1 == ModelPlatform.claudeCode { return false }
            return $0 < $1
        }
        let tokenStop = try? TheaterQueries.latestTokenStop(db, sinceMs: nowMs - PetTheater.eatWindowMs)
        lastTokenStopMs = (tokenStop ?? nil)?.ts
        lastTokenStopTokens = (tokenStop ?? nil)?.tokens ?? 0
        lastPrEventMs = (try? TheaterQueries.latestPRCelebrationMs(db, sinceMs: nowMs - 120_000)) ?? nil
        let stops = (try? CompletionWatch.recentCompletions(db: db, nowMs: nowMs)) ?? []
        if let completed = completionDetector.newlyCompleted(stops).first {
            lastTaskCompletionMs = completed.tsMs
        } else if let ts = lastTaskCompletionMs, nowMs - ts > 20_000 {
            lastTaskCompletionMs = nil
        }
        lastClickMs = (try? TheaterQueries.latestClickMs(db)) ?? nil
        lastEventMs = (try? TheaterQueries.latestEventMs(db)) ?? nil
        recentTool = recent?.lastTool
        workingDurationSeconds = longest
        permissionPending = !((try? PermissionWatch.pending(
            db: db, nowMs: nowMs, maxAgeMs: 60_000
        )) ?? []).isEmpty
        hungry = pet.fullness < Self.hungryFullness
        if hungry {
            if hungrySinceMs == nil { hungrySinceMs = nowMs }
        } else {
            hungrySinceMs = nil
        }
        isSick = base.animation == .sick
        isHibernating = pet.hibernationSince != nil
        let hour = Calendar.current.component(.hour, from: Date())
        behaviorEnvironment.localHour = hour
        if !workingSessions.isEmpty {
            let sampleKey = "\(dayKey)-\(hour)"
            if behaviorProfile.recordWorkHour(hour, sampleKey: sampleKey) { saveBehaviorProfile() }
        }
        let mem = systemMemPressure?()
        let thermal = systemThermal?()
        if mem != nil || thermal != nil {
            visual = PetVisual(
                stage: base.stage, animation: base.animation,
                overlay: SystemMood.combine(
                    base: base.overlay, mem: mem ?? .normal, thermal: thermal ?? .nominal
                )
            )
        } else {
            visual = base
        }

        if pet.hibernationSince != nil {
            activity = "💤 休眠中"
            isAgentWorking = false
            activePlatforms = []
        } else if let tool = recent?.lastTool {
            activity = "正在使用 \(tool)…"
        } else if !workingSessions.isEmpty {
            activity = workingSessions.count > 1
                ? "\(workingSessions.count) 个 Agent 正在工作…"
                : "Agent 正在工作…"
        } else {
            activity = "空闲"
        }
    }

    func makeSignals(memPressureHigh: Bool) -> TheaterSignals {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let drop = lastTokenStopMs.map { TokenDrop(tokens: lastTokenStopTokens, ageMs: nowMs - $0) }
        let idleSeconds = lastEventMs.map { Double(max(0, nowMs - $0)) / 1000 } ?? .greatestFiniteMagnitude
        let hungrySince = hungrySinceMs.map { Double(max(0, nowMs - $0)) / 1000 }
        return TheaterSignals(
            workingAgentCount: workingCount,
            recentTokenDrop: drop,
            prCelebration: lastPrEventMs != nil || lastTaskCompletionMs != nil,
            idleSeconds: idleSeconds,
            hibernating: isHibernating,
            sick: isSick,
            hungry: hungry,
            memPressureHigh: memPressureHigh,
            recentClickAgeMs: lastClickMs.map { nowMs - $0 },
            hungrySinceSeconds: hungrySince,
            intimacyHigh: intimacy >= Self.intimacyHighThreshold,
            tokenEventID: lastTokenStopMs,
            celebrationEventID: [lastPrEventMs, lastTaskCompletionMs].compactMap { $0 }.max(),
            clickEventID: lastClickMs,
            activeTool: recentTool,
            workingDurationSeconds: workingDurationSeconds,
            permissionPending: permissionPending
        )
    }

    /// Selects once at behavior boundaries and renders from an action-relative
    /// clock. All UI surfaces call this shared path, so the pet cannot be typing
    /// in the island while sleeping in the dropdown.
    func theaterScene(signals: TheaterSignals, timeMs: Int64) -> SceneFrame {
        let decision = behaviorBrain.decide(
            signals: signals, environment: behaviorEnvironment, nowMs: timeMs,
            personality: look.personality, genomeSeed: behaviorSeed, profile: behaviorProfile
        )
        return PetTheater.scene(
            behavior: decision.behavior, signals: signals,
            actionTimeMs: decision.elapsed(at: timeMs), personality: look.personality,
            idleVariant: decision.variant
        )
    }

    func updateDesktopEnvironment(_ environment: PetEnvironment) {
        var next = environment
        next.dragEventID = behaviorEnvironment.dragEventID
        behaviorEnvironment = next
    }

    func leaveDesktopEnvironment() {
        behaviorEnvironment.isDesktop = false
        behaviorEnvironment.cursorDistance = nil
        behaviorEnvironment.cursorSpeed = 0
        behaviorEnvironment.nearScreenEdge = false
        behaviorEnvironment.windowEventID = nil
    }

    func recordDragLanding() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        behaviorEnvironment.dragEventID = nowMs
        behaviorProfile.dragCount += 1
        saveBehaviorProfile()
    }

    /// Forwards each rendered theater frame to the sound layer. No-op unless the
    /// app wired `theaterSound`; only the dropdown theater feeds this.
    func observeTheater(_ scene: SceneFrame, nowMs: Int64) {
        theaterSound?(scene, nowMs)
    }

    /// Returns whether the tap was counted (cooldown passed → reward path). A
    /// blocked tap still deserves a small visual reaction, driven view-side.
    @discardableResult
    func handlePetClick() -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard let pet = try? Pet.fetchAlive(from: db), let petId = pet.id else { return false }
        let last = try? PetClickGate.lastClickMs(db)
        let cooldown = config.thresholds.petClickCooldownSeconds
        guard PetClick.allowed(lastClickMs: last ?? nil, nowMs: nowMs, cooldownSeconds: cooldown) else { return false }

        writeIntimacyEvent(eventId: "click:\(petId):\(nowMs)", type: .petClick, nowMs: nowMs)
        reinforceCurrentBehavior(amount: 0.035)
        return true
    }

    /// Long-press petting accrues intimacy, capped to one bucket per window via a
    /// deterministic event id (idempotent on replay).
    func handlePetting() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        guard PetPetting.shouldAccrue(lastAccrualMs: lastPettingAccrualMs, nowMs: nowMs) else { return }
        guard let pet = try? Pet.fetchAlive(from: db), let petId = pet.id else { return }
        writeIntimacyEvent(eventId: PetPetting.eventId(petId: petId, nowMs: nowMs), type: .petting, nowMs: nowMs)
        lastPettingAccrualMs = nowMs
        reinforceCurrentBehavior(amount: 0.06)
    }

    private func writeIntimacyEvent(eventId: String, type: Event.EventType, nowMs: Int64) {
        let event = Event(
            schemaVersion: 1, eventId: eventId, ts: nowMs, type: type,
            sessionId: nil, tool: nil, tokensIn: nil, tokensOut: nil, model: nil
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

    private func reinforceCurrentBehavior(amount: Double) {
        guard let current = behaviorBrain.current else { return }
        behaviorProfile.reinforce(current.behavior, amount: amount)
        saveBehaviorProfile()
    }

    private static func loadBehaviorProfile(key: String) -> PetBehaviorProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(PetBehaviorProfile.self, from: data)
        else { return PetBehaviorProfile() }
        return profile
    }

    private func saveBehaviorProfile() {
        guard let key = behaviorProfileKey,
              let data = try? JSONEncoder().encode(behaviorProfile)
        else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
