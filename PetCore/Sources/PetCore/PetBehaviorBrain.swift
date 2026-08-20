import Foundation

/// Lightweight desktop context. The App fills this without Accessibility or
/// Screen Recording permission; PetCore only uses it to bias autonomous choices.
public struct PetEnvironment: Equatable {
    public var isDesktop: Bool
    public var cursorDistance: Double?
    public var cursorSpeed: Double
    public var nearScreenEdge: Bool
    public var dragEventID: Int64?
    public var windowEventID: Int64?
    public var localHour: Int
    public var userIdleSeconds: Double

    public init(
        isDesktop: Bool = false, cursorDistance: Double? = nil, cursorSpeed: Double = 0,
        nearScreenEdge: Bool = false, dragEventID: Int64? = nil,
        windowEventID: Int64? = nil, localHour: Int = 12, userIdleSeconds: Double = 0
    ) {
        self.isDesktop = isDesktop
        self.cursorDistance = cursorDistance
        self.cursorSpeed = cursorSpeed
        self.nearScreenEdge = nearScreenEdge
        self.dragEventID = dragEventID
        self.windowEventID = windowEventID
        self.localHour = localHour
        self.userIdleSeconds = userIdleSeconds
    }
}

/// Small, persisted memory. It deliberately stores preferences rather than a
/// transcript: interaction reinforces whatever the pet was doing, while a work
/// hour histogram lets its rhythm gradually match the owner.
public struct PetBehaviorProfile: Codable, Equatable {
    public var affinity: [String: Double]
    public var workHours: [Int]
    public var affectionCount: Int
    public var dragCount: Int
    public var lastSampledHourKey: String?

    public init(
        affinity: [String: Double] = [:], workHours: [Int] = Array(repeating: 0, count: 24),
        affectionCount: Int = 0, dragCount: Int = 0, lastSampledHourKey: String? = nil
    ) {
        self.affinity = affinity
        self.workHours = workHours.count == 24 ? workHours : Array(repeating: 0, count: 24)
        self.affectionCount = affectionCount
        self.dragCount = dragCount
        self.lastSampledHourKey = lastSampledHourKey
    }

    public mutating func reinforce(_ behavior: TheaterBehavior, amount: Double) {
        let key = behavior.rawValue
        affinity[key] = min(1.75, max(0.65, (affinity[key] ?? 1) + amount))
        affectionCount += 1
    }

    public mutating func recordWorkHour(_ hour: Int, sampleKey: String) -> Bool {
        guard (0..<24).contains(hour), lastSampledHourKey != sampleKey else { return false }
        workHours[hour] = min(10_000, workHours[hour] + 1)
        lastSampledHourKey = sampleKey
        return true
    }

    public func workAffinity(hour: Int) -> Double {
        guard (0..<24).contains(hour), let peak = workHours.max(), peak > 0 else { return 1 }
        return 0.85 + 0.3 * Double(workHours[hour]) / Double(peak)
    }
}

public struct BehaviorDecision: Equatable {
    public let behavior: TheaterBehavior
    public let startedAtMs: Int64
    public let durationMs: Int64
    public let variant: Int
    public let sequence: Int64

    public init(
        behavior: TheaterBehavior, startedAtMs: Int64, durationMs: Int64,
        variant: Int = 0, sequence: Int64 = 0
    ) {
        self.behavior = behavior
        self.startedAtMs = startedAtMs
        self.durationMs = durationMs
        self.variant = variant
        self.sequence = sequence
    }

    public func elapsed(at nowMs: Int64) -> Int64 { max(0, nowMs - startedAtMs) }
}

/// Stateful utility selector. Randomness only happens at decision boundaries,
/// so animation remains coherent; recency, cooldowns and a surprise budget keep
/// the result varied without becoming noisy.
public struct PetBehaviorBrain {
    private struct Candidate {
        let behavior: TheaterBehavior
        var weight: Double
        let minMs: Int64
        let maxMs: Int64
        var cooldownMs: Int64
        var salient: Bool = false
    }

    public private(set) var current: BehaviorDecision?
    public private(set) var recent: [TheaterBehavior] = []
    private var cooldownUntil: [TheaterBehavior: Int64] = [:]
    private var consumedEvents: Set<String> = []
    private var sequence: Int64 = 0
    private var lastSalientAtMs: Int64 = .min
    private var lastWindowEventID: Int64?

    public init() {}

    public mutating func reset() {
        current = nil
        recent = []
        cooldownUntil = [:]
        consumedEvents = []
        sequence = 0
        lastSalientAtMs = .min
        lastWindowEventID = nil
    }

    public mutating func decide(
        signals: TheaterSignals, environment: PetEnvironment, nowMs: Int64,
        personality: TheaterPersonality, genomeSeed: UInt64,
        profile: PetBehaviorProfile = PetBehaviorProfile()
    ) -> BehaviorDecision {
        if let forced = forcedBehavior(signals, environment: environment, nowMs: nowMs) {
            if current?.behavior != forced.behavior
                || current.map({ nowMs >= $0.startedAtMs + $0.durationMs }) != false
                || forced.isOneShot {
                return begin(
                    forced.behavior, nowMs: nowMs, durationMs: forced.durationMs,
                    genomeSeed: genomeSeed, cooldownMs: forced.cooldownMs,
                    salient: forced.salient
                )
            }
        }

        if let current, nowMs < current.startedAtMs + current.durationMs { return current }

        var effectiveEnvironment = environment
        if let id = environment.windowEventID {
            if id == lastWindowEventID { effectiveEnvironment.windowEventID = nil }
            else { lastWindowEventID = id }
        }
        var candidates = signals.workingAgentCount > 0
            ? workCandidates(signals, environment: effectiveEnvironment, personality: personality)
            : ambientCandidates(signals, environment: effectiveEnvironment, personality: personality)

        candidates = candidates.compactMap { candidate in
            var c = candidate
            if (cooldownUntil[c.behavior] ?? .min) > nowMs { return nil }
            if recent.suffix(2).contains(c.behavior) { return nil }
            if recent.suffix(4).contains(c.behavior) { c.weight *= 0.22 }
            if c.salient, lastSalientAtMs != .min,
               nowMs - lastSalientAtMs < 180_000 { c.weight *= 0.08 }
            c.weight *= min(1.75, max(0.65, profile.affinity[c.behavior.rawValue] ?? 1))
            c.weight *= traitMultiplier(c.behavior, personality: personality)
            if signals.workingAgentCount > 0 {
                c.weight *= profile.workAffinity(hour: environment.localHour)
            }
            return c.weight > 0.001 ? c : nil
        }

        if candidates.isEmpty {
            candidates = [Candidate(
                behavior: signals.workingAgentCount > 0 ? .work : .idle,
                weight: 1, minMs: 4_000, maxMs: 8_000, cooldownMs: 0
            )]
        }

        var rng = decisionRNG(seed: genomeSeed, salt: "choose")
        let noisy = candidates.map { c -> Candidate in
            var copy = c
            copy.weight *= Double.random(in: 0.78...1.22, using: &rng)
            return copy
        }
        let total = noisy.reduce(0) { $0 + $1.weight }
        var roll = Double.random(in: 0..<max(total, 0.001), using: &rng)
        let chosen = noisy.first { c in
            roll -= c.weight
            return roll <= 0
        } ?? noisy.last!
        let sampled = Int64.random(in: chosen.minMs...max(chosen.minMs, chosen.maxMs), using: &rng)
        let loop = PetTheater.loopMs(chosen.behavior, signals: signals)
        let loopCount = max(1, Int((Double(sampled) / Double(loop)).rounded()))
        let duration = loop * Int64(loopCount)
        return begin(
            chosen.behavior, nowMs: nowMs, durationMs: duration,
            genomeSeed: genomeSeed, cooldownMs: chosen.cooldownMs, salient: chosen.salient
        )
    }

    private mutating func begin(
        _ behavior: TheaterBehavior, nowMs: Int64, durationMs: Int64,
        genomeSeed: UInt64, cooldownMs: Int64, salient: Bool
    ) -> BehaviorDecision {
        sequence &+= 1
        var rng = GenomeRNG(seed: genomeSeed ^ UInt64(bitPattern: sequence), stream: "behavior.variant")
        let decision = BehaviorDecision(
            behavior: behavior, startedAtMs: nowMs, durationMs: max(600, durationMs),
            variant: Int.random(in: 0..<97, using: &rng), sequence: sequence
        )
        current = decision
        recent.append(behavior)
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        if cooldownMs > 0 { cooldownUntil[behavior] = nowMs + cooldownMs }
        if salient { lastSalientAtMs = nowMs }
        return decision
    }

    private struct Forced {
        let behavior: TheaterBehavior
        let durationMs: Int64
        let cooldownMs: Int64
        let salient: Bool
        let isOneShot: Bool
    }

    private mutating func forcedBehavior(
        _ s: TheaterSignals, environment e: PetEnvironment, nowMs: Int64
    ) -> Forced? {
        if s.pettingActive { return Forced(behavior: .petting, durationMs: 2_640, cooldownMs: 0, salient: false, isOneShot: false) }
        if s.comboTap { return Forced(behavior: .dizzy, durationMs: 2_000, cooldownMs: 8_000, salient: true, isOneShot: false) }
        if s.sick { return Forced(behavior: .sickDroop, durationMs: 4_000, cooldownMs: 0, salient: false, isOneShot: false) }
        if s.hibernating { return Forced(behavior: .nap, durationMs: 8_000, cooldownMs: 0, salient: false, isOneShot: false) }
        if s.permissionPending {
            return Forced(behavior: .permissionWait, durationMs: 4_800, cooldownMs: 0, salient: false, isOneShot: false)
        }

        if let id = e.dragEventID, consume("drag:\(id)") {
            return Forced(behavior: .landing, durationMs: 2_800, cooldownMs: 12_000, salient: true, isOneShot: true)
        }
        if s.prCelebration, let id = s.celebrationEventID, consume("complete:\(id)") {
            let longTask = s.workingDurationSeconds > 900
            return Forced(behavior: longTask ? .celebrate : .proud, durationMs: longTask ? 4_160 : 3_200, cooldownMs: 30_000, salient: true, isOneShot: true)
        }
        if let d = s.recentTokenDrop, d.ageMs <= PetTheater.eatWindowMs,
           d.tokens >= PetTheater.eatMinTokens, let id = s.tokenEventID,
           consume("tokens:\(id)") {
            return Forced(behavior: .eat, durationMs: 4_320, cooldownMs: 20_000, salient: false, isOneShot: true)
        }
        if let age = s.recentClickAgeMs, age <= PetTheater.greetWindowMs,
           let id = s.clickEventID, consume("click:\(id)") {
            return Forced(behavior: .greet, durationMs: 2_400, cooldownMs: 6_000, salient: true, isOneShot: true)
        }
        return nil
    }

    private mutating func consume(_ key: String) -> Bool {
        guard !consumedEvents.contains(key) else { return false }
        consumedEvents.insert(key)
        if consumedEvents.count > 128 { consumedEvents.removeAll(keepingCapacity: true) }
        return true
    }

    private func workCandidates(
        _ s: TheaterSignals, environment e: PetEnvironment, personality p: TheaterPersonality
    ) -> [Candidate] {
        var out = [
            Candidate(behavior: .work, weight: 5.2, minMs: 7_000, maxMs: Int64(16_000 * p.patience), cooldownMs: 0),
            Candidate(behavior: .think, weight: 1.7, minMs: 3_000, maxMs: 7_000, cooldownMs: 7_000),
            Candidate(behavior: .read, weight: toolLooksLikeReading(s.activeTool) ? 3.5 : 0.8, minMs: 4_000, maxMs: 9_000, cooldownMs: 8_000),
            Candidate(behavior: .multitask, weight: s.workingAgentCount > 1 ? Double(s.workingAgentCount) * 1.4 : 0, minMs: 4_000, maxMs: 8_000, cooldownMs: 12_000),
            Candidate(behavior: .workBreak, weight: s.workingDurationSeconds > 1_200 ? 1.5 : 0.25, minMs: 3_500, maxMs: 7_000, cooldownMs: 45_000),
        ]
        if e.isDesktop, let d = e.cursorDistance, d < 95 {
            out.append(Candidate(behavior: .cursorWatch, weight: 0.55, minMs: 2_500, maxMs: 4_500, cooldownMs: 25_000))
        }
        return out
    }

    private func ambientCandidates(
        _ s: TheaterSignals, environment e: PetEnvironment, personality p: TheaterPersonality
    ) -> [Candidate] {
        let late = e.localHour >= 23 || e.localHour < 7
        let cursorNear = e.isDesktop && (e.cursorDistance ?? .greatestFiniteMagnitude) < 150
        let cursorVeryNear = e.isDesktop && (e.cursorDistance ?? .greatestFiniteMagnitude) < 85
        var out = [
            Candidate(behavior: .idle, weight: 5.4, minMs: 3_500, maxMs: 9_000, cooldownMs: 0),
            Candidate(behavior: .lookAround, weight: 2.2, minMs: 2_800, maxMs: 5_500, cooldownMs: 5_000),
            Candidate(behavior: .groom, weight: 1.5, minMs: 3_200, maxMs: 6_000, cooldownMs: 18_000),
            Candidate(behavior: .stroll, weight: s.idleSeconds > 20 ? 1.7 : 0.45, minMs: 4_000, maxMs: 8_000, cooldownMs: 12_000),
            Candidate(behavior: .yawn, weight: late || e.userIdleSeconds > 300 ? 1.8 : 0.35, minMs: 3_000, maxMs: 5_000, cooldownMs: 45_000),
            Candidate(behavior: .doze, weight: late || e.userIdleSeconds > 900 ? 2.5 : 0.25, minMs: 8_000, maxMs: 22_000, cooldownMs: 50_000),
            Candidate(behavior: .cursorWatch, weight: cursorNear ? 2.4 : 0, minMs: 2_500, maxMs: 5_000, cooldownMs: 14_000),
            Candidate(behavior: .cursorChase, weight: cursorVeryNear && e.cursorSpeed > 80 ? 1.6 : 0, minMs: 3_200, maxMs: 6_500, cooldownMs: 40_000, salient: true),
            Candidate(behavior: .peek, weight: e.isDesktop && e.nearScreenEdge ? 1.35 : 0, minMs: 4_000, maxMs: 7_000, cooldownMs: 45_000, salient: true),
            Candidate(behavior: .windowWatch, weight: e.isDesktop && e.windowEventID != nil ? 0.9 : 0.15, minMs: 3_000, maxMs: 6_000, cooldownMs: 30_000),
            Candidate(behavior: .beg, weight: s.hungry ? 1.7 : 0, minMs: 4_000, maxMs: 6_000, cooldownMs: 30_000),
            Candidate(behavior: .attention, weight: PetTheater.wantsAttention(s) ? 0.9 : 0, minMs: 3_500, maxMs: 5_000, cooldownMs: 90_000, salient: true),
        ]
        if p.energy < 0.85 { out[0].weight *= 1.25 }
        return out
    }

    private func traitMultiplier(_ b: TheaterBehavior, personality p: TheaterPersonality) -> Double {
        switch b {
        case .cursorWatch, .windowWatch, .peek, .lookAround: return p.curiosity
        case .cursorChase, .landing, .dizzy, .stroll: return p.playfulness * p.energy
        case .greet, .attention, .petting, .permissionWait: return p.sociability
        case .work, .read, .think, .multitask: return p.patience
        case .doze, .yawn, .workBreak: return 2 - min(1.4, p.energy) * 0.55
        default: return 1
        }
    }

    private func toolLooksLikeReading(_ tool: String?) -> Bool {
        guard let value = tool?.lowercased() else { return false }
        return ["read", "grep", "glob", "search", "find", "open", "web"].contains { value.contains($0) }
    }

    private func decisionRNG(seed: UInt64, salt: String) -> GenomeRNG {
        GenomeRNG(seed: seed ^ UInt64(bitPattern: sequence &+ 1), stream: "behavior.\(salt)")
    }
}
