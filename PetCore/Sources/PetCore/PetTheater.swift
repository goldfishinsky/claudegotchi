import Foundation

// MARK: - signals

public struct TokenDrop: Equatable {
    public let tokens: Int64
    public let ageMs: Int64
    public init(tokens: Int64, ageMs: Int64) {
        self.tokens = tokens
        self.ageMs = ageMs
    }
}

/// Everything the theater needs to decide what the pet performs, sampled from
/// the app's live models. Pure value type so behaviour selection is testable.
public struct TheaterSignals: Equatable {
    public var workingAgentCount: Int
    public var recentTokenDrop: TokenDrop?
    public var prCelebration: Bool
    public var idleSeconds: Double
    public var hibernating: Bool
    public var sick: Bool
    public var hungry: Bool
    public var memPressureHigh: Bool
    public var recentClickAgeMs: Int64?
    public var hungrySinceSeconds: Double?
    public var intimacyHigh: Bool
    public var pettingActive: Bool
    public var comboTap: Bool
    public var lastTapAgeMs: Int64?
    public var lastTapCounted: Bool
    public var tokenEventID: Int64?
    public var celebrationEventID: Int64?
    public var clickEventID: Int64?
    public var activeTool: String?
    public var workingDurationSeconds: Double
    public var permissionPending: Bool

    public init(
        workingAgentCount: Int = 0,
        recentTokenDrop: TokenDrop? = nil,
        prCelebration: Bool = false,
        idleSeconds: Double = 0,
        hibernating: Bool = false,
        sick: Bool = false,
        hungry: Bool = false,
        memPressureHigh: Bool = false,
        recentClickAgeMs: Int64? = nil,
        hungrySinceSeconds: Double? = nil,
        intimacyHigh: Bool = false,
        pettingActive: Bool = false,
        comboTap: Bool = false,
        lastTapAgeMs: Int64? = nil,
        lastTapCounted: Bool = false,
        tokenEventID: Int64? = nil,
        celebrationEventID: Int64? = nil,
        clickEventID: Int64? = nil,
        activeTool: String? = nil,
        workingDurationSeconds: Double = 0,
        permissionPending: Bool = false
    ) {
        self.workingAgentCount = workingAgentCount
        self.recentTokenDrop = recentTokenDrop
        self.prCelebration = prCelebration
        self.idleSeconds = idleSeconds
        self.hibernating = hibernating
        self.sick = sick
        self.hungry = hungry
        self.memPressureHigh = memPressureHigh
        self.recentClickAgeMs = recentClickAgeMs
        self.hungrySinceSeconds = hungrySinceSeconds
        self.intimacyHigh = intimacyHigh
        self.pettingActive = pettingActive
        self.comboTap = comboTap
        self.lastTapAgeMs = lastTapAgeMs
        self.lastTapCounted = lastTapCounted
        self.tokenEventID = tokenEventID
        self.celebrationEventID = celebrationEventID
        self.clickEventID = clickEventID
        self.activeTool = activeTool
        self.workingDurationSeconds = workingDurationSeconds
        self.permissionPending = permissionPending
    }
}

// MARK: - easing

public enum Easing: Equatable {
    case linear, easeOut, easeInOut, easeOutBack

    public func apply(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        switch self {
        case .linear:
            return x
        case .easeOut:
            return 1 - pow(1 - x, 3)
        case .easeInOut:
            return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .easeOutBack:
            let c1 = 1.70158, c3 = 1.70158 + 1
            return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
        }
    }
}

public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: - behaviours

public enum TheaterBehavior: String, Equatable, Hashable, Codable, CaseIterable {
    case celebrate, eat, greet, work, sickDroop, stroll, idle, nap
    case dizzy, beg, attention, petting
    case lookAround, groom, yawn, doze
    case cursorWatch, cursorChase, peek, landing, windowWatch
    case think, read, multitask, workBreak, proud
    case permissionWait
}

// MARK: - particles

public enum ParticleKind: String, Equatable {
    case heartRise, confettiFall, keystrokeSparks, zDrift, crumbBurst, tapDust
}

/// An emission resolved at a point in time: a burst of `count` particles born
/// `ageMs` ago at (originX, originY) in pet-home grid cells. Motion is derived
/// purely from (seed, index, ageMs) by `ParticleSim`.
public struct ActiveEmission: Equatable {
    public let kind: ParticleKind
    public let originX: Double
    public let originY: Double
    public let count: Int
    public let seed: UInt64
    public let ageMs: Int64
    public init(kind: ParticleKind, originX: Double, originY: Double, count: Int, seed: UInt64, ageMs: Int64) {
        self.kind = kind
        self.originX = originX
        self.originY = originY
        self.count = count
        self.seed = seed
        self.ageMs = ageMs
    }
}

public enum ParticleSim {
    public struct P: Equatable {
        public let x: Double
        public let y: Double
        public let alpha: Double
        public init(x: Double, y: Double, alpha: Double) {
            self.x = x; self.y = y; self.alpha = alpha
        }
    }

    public static func lifetimeMs(_ k: ParticleKind) -> Int64 {
        switch k {
        case .heartRise: return 1300
        case .confettiFall: return 1500
        case .keystrokeSparks: return 520
        case .zDrift: return 2200
        case .crumbBurst: return 620
        case .tapDust: return 400
        }
    }

    private static func hash(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a &* 0x9E37_79B9_7F4A_7C15 &+ b &* 0xD1B5_4A32_D192_ED03
        x ^= x >> 30; x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return x
    }

    private static func unit(_ seed: UInt64, _ i: Int, _ salt: UInt64) -> Double {
        let h = hash(hash(seed, UInt64(bitPattern: Int64(i))), salt)
        return Double(h >> 11) / Double(UInt64(1) << 53)
    }

    public static func particles(_ e: ActiveEmission) -> [P] {
        let life = Double(lifetimeMs(e.kind))
        var out: [P] = []
        out.reserveCapacity(e.count)
        for i in 0..<e.count {
            let r0 = unit(e.seed, i, 1)
            let r1 = unit(e.seed, i, 2)
            let r2 = unit(e.seed, i, 3)
            // stagger births slightly so bursts don't fire as one hard block
            let bornOffset = r0 * 0.18 * life
            let t = min(1, max(0, (Double(e.ageMs) - bornOffset) / life))
            if Double(e.ageMs) < bornOffset { continue }
            out.append(pos(e.kind, ox: e.originX, oy: e.originY, t: t, r0: r0, r1: r1, r2: r2))
        }
        return out
    }

    private static func pos(_ k: ParticleKind, ox: Double, oy: Double, t: Double,
                            r0: Double, r1: Double, r2: Double) -> P {
        switch k {
        case .heartRise:
            let x = ox + sin(t * 6.0 + r0 * 6.28) * (0.5 + r1 * 0.5)
            let y = oy - t * (4.0 + r1 * 1.6)
            let a = min(1, (1 - t) * 1.7)
            return P(x: x, y: y, alpha: a)
        case .confettiFall:
            let vy0 = -(2.6 + r0 * 1.8)
            let g = 11.0
            let y = oy + vy0 * t + 0.5 * g * t * t
            let x = ox + (r1 - 0.5) * 7.5 * t + sin(t * 9 + r2 * 6.28) * 0.7
            let a = t < 0.8 ? 1.0 : max(0, (1 - t) / 0.2)
            return P(x: x, y: y, alpha: a)
        case .keystrokeSparks:
            let y = oy - t * 2.1 - sin(t * .pi) * 0.5
            let x = ox + (r0 - 0.5) * 2.6
            return P(x: x, y: y, alpha: 1 - t)
        case .zDrift:
            let y = oy - t * 4.4
            let x = ox + t * 2.4 + sin(t * 3.5 + r0 * 6.28) * 0.5
            let a = min(1, (1 - t) * 1.4)
            return P(x: x, y: y, alpha: a)
        case .crumbBurst:
            let ang = -0.3 - r0 * 2.5
            let speed = 1.8 + r1 * 2.0
            let x = ox + cos(ang) * speed * t
            let y = oy + sin(ang) * speed * t + 4.2 * t * t
            return P(x: x, y: y, alpha: 1 - t)
        case .tapDust:
            let x = ox + (r0 - 0.5) * 1.3
            let y = oy - t * 1.6
            return P(x: x, y: y, alpha: (1 - t) * 0.55)
        }
    }
}

// MARK: - scene output

public struct PropInstance: Equatable {
    public let sprite: PropSprite
    public let x: Double
    public let y: Double
    public let front: Bool
    public init(sprite: PropSprite, x: Double, y: Double, front: Bool = false) {
        self.sprite = sprite; self.x = x; self.y = y; self.front = front
    }
}

public struct SceneFrame: Equatable {
    public let behavior: TheaterBehavior
    public let phaseIndex: Int
    public let petOffsetX: Double
    public let petOffsetY: Double
    public let squash: Double
    public let frameKey: String
    public let frame: Int
    public let props: [PropInstance]
    public let emissions: [ActiveEmission]
    public let bubble: String?
}

// MARK: - phase model (internal)

struct Emit {
    let kind: ParticleKind
    let localX: Double
    let localY: Double
    let count: Int
    let seed: UInt64
}

struct Phase {
    let duration: Double
    let frameKey: String
    let frame: Int
    let fromX: Double, fromY: Double
    let toX: Double, toY: Double
    let ease: Easing
    let squashFrom: Double
    let squashTo: Double
    var stepping: Int = 0            // >0 = walk cycle with this many steps
    var props: [PropInstance] = []
    var emits: [Emit] = []
    var bubble: String? = nil
    var action: String? = nil        // action-clocked frames, overriding frameKey/frame
}

struct Behavior {
    let kind: TheaterBehavior
    let loopMs: Int64
    let phases: [Phase]
}

// MARK: - engine

public enum PetTheater {
    // trigger windows
    public static let eatWindowMs: Int64 = 90_000
    public static let eatMinTokens: Int64 = 400
    public static let greetWindowMs: Int64 = 5_000
    public static let strollAfterSeconds: Double = 25
    public static let strollUntilSeconds: Double = 240
    public static let begAfterSeconds: Double = 120
    public static let attentionIdleSeconds: Double = 240
    public static let attentionNoClickMs: Int64 = 600_000
    public static let tapReactionMs: Int64 = 400

    /// Stage row every prop is planted on, and the line the action layer measures
    /// prop-relative poses (typing paws) against.
    public static let stageFloorY: Double = 16.5

    public static func selectBehavior(_ s: TheaterSignals) -> TheaterBehavior {
        if s.prCelebration { return .celebrate }
        if s.pettingActive { return .petting }
        if let d = s.recentTokenDrop, d.ageMs <= eatWindowMs, d.tokens >= eatMinTokens { return .eat }
        if s.comboTap { return .dizzy }
        if let c = s.recentClickAgeMs, c <= greetWindowMs { return .greet }
        if s.workingAgentCount > 0 { return .work }
        if s.sick { return .sickDroop }
        if s.hibernating { return .nap }
        if let hs = s.hungrySinceSeconds, hs > begAfterSeconds { return .beg }
        if s.idleSeconds >= strollAfterSeconds, s.idleSeconds <= strollUntilSeconds { return .stroll }
        if wantsAttention(s) { return .attention }
        return .idle
    }

    static func wantsAttention(_ s: TheaterSignals) -> Bool {
        guard s.idleSeconds > attentionIdleSeconds, !s.sick, !s.hibernating else { return false }
        return (s.recentClickAgeMs ?? Int64.max) > attentionNoClickMs
    }

    /// Transient press-down bounce (1.0 → 0.88 → 1.05 → 1.0) for a cooldown-blocked
    /// tap. Composed multiplicatively over the current behaviour's squash; nil once
    /// the reaction window has elapsed.
    public static func tapReactionSquash(ageMs: Int64) -> Double? {
        guard ageMs >= 0, ageMs < tapReactionMs else { return nil }
        let t = Double(ageMs) / Double(tapReactionMs)
        if t < 0.30 { return lerp(1.0, 0.88, Easing.easeOut.apply(t / 0.30)) }
        if t < 0.60 { return lerp(0.88, 1.05, Easing.easeOut.apply((t - 0.30) / 0.30)) }
        return lerp(1.05, 1.0, Easing.easeInOut.apply((t - 0.60) / 0.40))
    }

    // MARK: idle fidget pool

    public static let fidgetVariants = 5
    public static let fidgetLoopMs: Int64 = 3800

    /// Deterministic variant for a given idle-loop bucket. A coprime step over the
    /// variant count rotates through every fidget (full coverage) and can never land
    /// on the same variant two buckets running (guaranteed no immediate repeat).
    public static func fidgetIndex(bucket: Int64) -> Int {
        let n = Int64(fidgetVariants)
        let step: Int64 = 2
        let b = ((bucket % n) + n) % n
        return Int((b * step) % n)
    }

    static func floorDivInt(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func idleFidget(bucket: Int64) -> Behavior {
        switch fidgetIndex(bucket: bucket) {
        case 0: return fidgetEarScratch()
        case 1: return fidgetLookLeft()
        case 2: return fidgetLookRight()
        case 3: return fidgetBlinkHold()
        default: return fidgetStretch()
        }
    }

    /// Personality-biased fidget: neutral (empty weights) keeps the coprime rotation
    /// unchanged; a genome pet biases the pick via its `fidgetWeights` (mapped to the
    /// pool, extra dims dropped) with `blinkRate` scaling the blink-hold variant.
    static func idleFidget(bucket: Int64, personality: TheaterPersonality) -> Behavior {
        guard !personality.fidgetWeights.isEmpty else { return idleFidget(bucket: bucket) }
        let builders: [() -> Behavior] = [
            fidgetEarScratch, fidgetLookLeft, fidgetLookRight, fidgetBlinkHold, fidgetStretch,
        ]
        var weights = poolWeights(personality.fidgetWeights, count: builders.count)
        weights[3] = max(0, weights[3] * personality.blinkRate)
        return builders[weightedFidget(weights, bucket: bucket)]()
    }

    static func poolWeights(_ w: [Double], count: Int) -> [Double] {
        if count <= w.count { return Array(w.prefix(count)) }
        let avg = w.isEmpty ? 1 : w.reduce(0, +) / Double(w.count)
        return w + Array(repeating: avg, count: count - w.count)
    }

    static func weightedFidget(_ weights: [Double], bucket: Int64) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        let roll = coin(salt: "fidget", bucket: bucket) * total
        var acc = 0.0
        for (i, wt) in weights.enumerated() {
            acc += wt
            if roll < acc { return i }
        }
        return weights.count - 1
    }

    /// Chatty pets (≥1.0) always speak — identical to the pre-genome behaviour;
    /// shy pets skip a fraction of speech bubbles, decided once per loop.
    static func bubbleAllowed(_ chattiness: Double, loopBucket: Int64, kind: TheaterBehavior) -> Bool {
        guard chattiness < 1.0 else { return true }
        return coin(salt: "chatter." + kind.rawValue, bucket: loopBucket) < chattiness
    }

    static func scaledClock(_ timeMs: Int64, _ speed: Double) -> Int64 {
        guard speed != 1.0 else { return timeMs }
        return Int64((Double(timeMs) * speed).rounded())
    }

    private static func coin(salt: String, bucket: Int64) -> Double {
        var z = GenomeRNG.fnv1a64(salt) ^ UInt64(bitPattern: bucket)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    public static func loopMs(_ k: TheaterBehavior, signals: TheaterSignals = TheaterSignals()) -> Int64 {
        behavior(k, signals: signals).loopMs
    }

    public static func foodSize(tokens: Int64) -> PropSprite {
        if tokens >= 8_000 { return .foodL }
        if tokens >= 2_000 { return .foodM }
        return .foodS
    }

    public static func scene(
        signals: TheaterSignals, timeMs: Int64, personality: TheaterPersonality = .neutral
    ) -> SceneFrame {
        scene(
            behavior: selectBehavior(signals), signals: signals,
            actionTimeMs: timeMs, personality: personality
        )
    }

    /// Renders an action chosen by `PetBehaviorBrain`. Its clock is relative to
    /// the start of that action, so opening another surface cannot jump the pet
    /// halfway through a performance.
    public static func scene(
        behavior kind: TheaterBehavior, signals: TheaterSignals, actionTimeMs: Int64,
        personality: TheaterPersonality = .neutral, idleVariant: Int = 0
    ) -> SceneFrame {
        let clock = scaledClock(actionTimeMs, personality.motionSpeed)
        let b = kind == .idle
            ? idleFidget(
                bucket: floorDivInt(clock, fidgetLoopMs) + Int64(idleVariant),
                personality: personality
            )
            : behavior(kind, signals: signals)
        let loop = b.loopMs
        let loopPos = ((clock % loop) + loop) % loop
        let frac = Double(loopPos) / Double(loop)

        // locate current phase
        var acc = 0.0
        var pIndex = 0
        var startFrac = 0.0
        for (i, p) in b.phases.enumerated() {
            if frac < acc + p.duration || i == b.phases.count - 1 {
                pIndex = i
                startFrac = acc
                break
            }
            acc += p.duration
        }
        let phase = b.phases[pIndex]
        let localT = phase.duration > 0
            ? min(1, max(0, (frac - startFrac) / phase.duration)) : 0
        let e = phase.ease.apply(localT)

        let offX = lerp(phase.fromX, phase.toX, e)
        var offY = lerp(phase.fromY, phase.toY, e)
        var frame = phase.frame
        var frameKey = phase.frameKey
        if phase.stepping > 0 {
            let s = Double(phase.stepping)
            frame = Int(localT * s) % 2
            offY -= abs(sin(localT * s * .pi)) * 0.5
        }
        if let action = phase.action, let cadence = BehaviorRhythm.cadence(action) {
            frameKey = action
            frame = BehaviorRhythm.frame(cadence, loopPos: loopPos)
        }
        if kind == .eat { offY += BehaviorActions.chewDip(loopPos: loopPos) }
        var squash = lerp(phase.squashFrom, phase.squashTo, e)

        // personality bounce: scale vertical travel + squash deviation (identity at 1.0)
        offY *= personality.bounceAmplitude
        squash = 1.0 + (squash - 1.0) * personality.bounceAmplitude

        // resolve active emissions across every phase (periodic, seamless)
        var emissions: [ActiveEmission] = []
        var cursor = 0.0
        for p in b.phases {
            let spawnMs = Int64(cursor * Double(loop))
            for em in p.emits {
                var age = loopPos - spawnMs
                if age < 0 { age += loop }
                if age <= ParticleSim.lifetimeMs(em.kind) {
                    emissions.append(ActiveEmission(
                        kind: em.kind,
                        originX: p.fromX + em.localX,
                        originY: p.fromY + em.localY,
                        count: em.count, seed: em.seed, ageMs: age
                    ))
                }
            }
            cursor += p.duration
        }

        var bubble = phase.bubble
        if kind == .idle, signals.hungry, bubble == nil, pIndex == 2 { bubble = "…" }
        if kind == .work, signals.memPressureHigh, bubble == nil, pIndex == 3 { bubble = "!" }
        if bubble != nil,
           !bubbleAllowed(personality.chattiness, loopBucket: floorDivInt(clock, loop), kind: kind) {
            bubble = nil
        }

        // Overlay reaction channel: a cooldown-blocked tap composes a small squash
        // bounce + one dim mote over whatever the pet is already doing, without
        // preempting it. Counted taps are rewarded by greet, so they skip this.
        var finalSquash = squash
        if let tapAge = signals.lastTapAgeMs, !signals.lastTapCounted,
           kind != .petting, kind != .dizzy,
           let react = tapReactionSquash(ageMs: tapAge) {
            finalSquash = squash * react
            emissions.append(ActiveEmission(
                kind: .tapDust, originX: 8 + offX, originY: offY, count: 1, seed: 0x7A17, ageMs: tapAge
            ))
        }

        return SceneFrame(
            behavior: kind, phaseIndex: pIndex,
            petOffsetX: offX, petOffsetY: offY, squash: finalSquash,
            frameKey: frameKey, frame: frame,
            props: struck(phase.props, kind: kind, loopPos: loopPos),
            emissions: emissions, bubble: bubble
        )
    }

    /// Lights the screen on the two typing frames where a paw is down, so the
    /// keystroke sparks, the paw strike and the terminal line land together.
    static func struck(_ props: [PropInstance], kind: TheaterBehavior, loopPos: Int64) -> [PropInstance] {
        guard kind == .work,
              BehaviorRhythm.frame(BehaviorRhythm.typing, loopPos: loopPos) % 2 == 0
        else { return props }
        return props.map {
            $0.sprite == .laptop
                ? PropInstance(sprite: .laptopLit, x: $0.x, y: $0.y, front: $0.front) : $0
        }
    }

    // MARK: behaviour catalogue

    static func behavior(_ k: TheaterBehavior, signals: TheaterSignals) -> Behavior {
        switch k {
        case .idle: return idleFidget(bucket: 0)
        case .stroll: return stroll()
        case .work: return work()
        case .celebrate: return celebrate(boosted: signals.intimacyHigh)
        case .eat: return eat(tokens: signals.recentTokenDrop?.tokens ?? 0)
        case .greet: return greet(boosted: signals.intimacyHigh)
        case .sickDroop: return sickDroop()
        case .nap: return nap()
        case .dizzy: return dizzy()
        case .beg: return beg()
        case .attention: return attention()
        case .petting: return petting()
        case .lookAround: return lookAround()
        case .groom: return groom()
        case .yawn: return yawn()
        case .doze: return doze()
        case .cursorWatch: return cursorWatch()
        case .cursorChase: return cursorChase()
        case .peek: return peek()
        case .landing: return landing()
        case .windowWatch: return windowWatch()
        case .think: return think()
        case .read: return read()
        case .multitask: return multitask()
        case .workBreak: return workBreak()
        case .proud: return proud()
        case .permissionWait: return permissionWait()
        }
    }

    private static func lookAround() -> Behavior {
        Behavior(kind: .lookAround, loopMs: 4200, phases: [
            Phase(duration: 0.22, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: -1.1, toY: 0, ease: .easeOut,
                  squashFrom: 1, squashTo: 0.98),
            Phase(duration: 0.26, frameKey: "idle", frame: 1,
                  fromX: -1.1, fromY: 0, toX: -1.1, toY: 0, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1, bubble: "?"),
            Phase(duration: 0.28, frameKey: "idle", frame: 0,
                  fromX: -1.1, fromY: 0, toX: 1.2, toY: 0, ease: .easeInOut,
                  squashFrom: 1, squashTo: 0.98),
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 1.2, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1),
        ])
    }

    private static func groom() -> Behavior {
        Behavior(kind: .groom, loopMs: 4800, phases: [
            Phase(duration: 0.22, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0.5, toY: 0.5, ease: .easeOut,
                  squashFrom: 1, squashTo: 0.9, action: "petting"),
            Phase(duration: 0.25, frameKey: "idle", frame: 1,
                  fromX: 0.5, fromY: 0.5, toX: -0.4, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.9, squashTo: 0.94, action: "petting"),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: -0.4, fromY: 0.4, toX: 0.4, toY: 0.5, ease: .easeInOut,
                  squashFrom: 0.94, squashTo: 0.9, action: "petting"),
            Phase(duration: 0.28, frameKey: "happy", frame: 0,
                  fromX: 0.4, fromY: 0.5, toX: 0, toY: 0, ease: .easeOutBack,
                  squashFrom: 0.9, squashTo: 1),
        ])
    }

    private static func yawn() -> Behavior {
        Behavior(kind: .yawn, loopMs: 4600, phases: [
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: -0.7, ease: .easeOut,
                  squashFrom: 1, squashTo: 1.1),
            Phase(duration: 0.25, frameKey: "sleeping", frame: 0,
                  fromX: 0, fromY: -0.7, toX: 0, toY: -0.7, ease: .easeInOut,
                  squashFrom: 1.1, squashTo: 1.04, bubble: "…"),
            Phase(duration: 0.22, frameKey: "sleeping", frame: 1,
                  fromX: 0, fromY: -0.7, toX: 0, toY: 0.5, ease: .easeInOut,
                  squashFrom: 1.04, squashTo: 0.9),
            Phase(duration: 0.28, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.5, toX: 0, toY: 0, ease: .easeOutBack,
                  squashFrom: 0.9, squashTo: 1),
        ])
    }

    private static func doze() -> Behavior {
        Behavior(kind: .doze, loopMs: 6000, phases: [
            Phase(duration: 0.34, frameKey: "sleeping", frame: 0,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.5, ease: .easeInOut,
                  squashFrom: 1, squashTo: 0.98,
                  emits: [Emit(kind: .zDrift, localX: 10, localY: 1, count: 1, seed: 0xD01)], action: "nap"),
            Phase(duration: 0.33, frameKey: "sleeping", frame: 1,
                  fromX: 0, fromY: 0.5, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1,
                  emits: [Emit(kind: .zDrift, localX: 10, localY: 1, count: 1, seed: 0xD02)], action: "nap"),
            Phase(duration: 0.33, frameKey: "sleeping", frame: 0,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 1, squashTo: 1, action: "nap"),
        ])
    }

    private static func cursorWatch() -> Behavior {
        Behavior(kind: .cursorWatch, loopMs: 3600, phases: [
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 1, toY: -0.3, ease: .easeOut,
                  squashFrom: 1, squashTo: 1.04, bubble: "?"),
            Phase(duration: 0.24, frameKey: "idle", frame: 1,
                  fromX: 1, fromY: -0.3, toX: 1.3, toY: -0.5, ease: .easeInOut,
                  squashFrom: 1.04, squashTo: 0.96),
            Phase(duration: 0.24, frameKey: "happy", frame: 0,
                  fromX: 1.3, fromY: -0.5, toX: 0.7, toY: -0.2, ease: .easeOutBack,
                  squashFrom: 0.96, squashTo: 1.05, action: "wave"),
            Phase(duration: 0.28, frameKey: "idle", frame: 0,
                  fromX: 0.7, fromY: -0.2, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.05, squashTo: 1),
        ])
    }

    private static func cursorChase() -> Behavior {
        Behavior(kind: .cursorChase, loopMs: 5200, phases: [
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 3.2, toY: 0, ease: .easeInOut,
                  squashFrom: 1, squashTo: 1, stepping: 5, action: "walk"),
            Phase(duration: 0.16, frameKey: "happy", frame: 0,
                  fromX: 3.2, fromY: 0, toX: 3.6, toY: -1.5, ease: .easeOutBack,
                  squashFrom: 1, squashTo: 1.12, bubble: "!", action: "wave"),
            Phase(duration: 0.18, frameKey: "happy", frame: 1,
                  fromX: 3.6, fromY: -1.5, toX: 2.7, toY: 0, ease: .easeInOut,
                  squashFrom: 1.12, squashTo: 0.9, action: "wave"),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 2.7, fromY: 0, toX: -1.2, toY: 0, ease: .easeInOut,
                  squashFrom: 0.9, squashTo: 1, stepping: 5, action: "walk"),
            Phase(duration: 0.16, frameKey: "idle", frame: 0,
                  fromX: -1.2, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1, squashTo: 1, stepping: 2, action: "walk"),
        ])
    }

    private static func peek() -> Behavior {
        Behavior(kind: .peek, loopMs: 5000, phases: [
            Phase(duration: 0.28, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 4.2, toY: 0, ease: .easeInOut,
                  squashFrom: 1, squashTo: 1, stepping: 5, action: "walk"),
            Phase(duration: 0.24, frameKey: "idle", frame: 1,
                  fromX: 4.2, fromY: 0, toX: 5.2, toY: 0.3, ease: .easeOut,
                  squashFrom: 1, squashTo: 0.94, bubble: "?"),
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 5.2, fromY: 0.3, toX: 4.2, toY: 0, ease: .easeInOut,
                  squashFrom: 0.94, squashTo: 1),
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 4.2, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1, squashTo: 1, stepping: 5, action: "walk"),
        ])
    }

    private static func landing() -> Behavior {
        Behavior(kind: .landing, loopMs: 2800, phases: [
            Phase(duration: 0.16, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: 0, toX: 0, toY: 0.8, ease: .easeOut,
                  squashFrom: 1, squashTo: 0.78,
                  emits: [Emit(kind: .tapDust, localX: 8, localY: 16, count: 4, seed: 0x1A)]),
            Phase(duration: 0.18, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.8, toX: 0.5, toY: -0.4, ease: .easeOutBack,
                  squashFrom: 0.78, squashTo: 1.12, bubble: "!"),
            Phase(duration: 0.2, frameKey: "idle", frame: 1,
                  fromX: 0.5, fromY: -0.4, toX: -0.5, toY: 0, ease: .easeInOut,
                  squashFrom: 1.12, squashTo: 0.96),
            Phase(duration: 0.2, frameKey: "idle", frame: 0,
                  fromX: -0.5, fromY: 0, toX: 0.3, toY: 0, ease: .easeInOut,
                  squashFrom: 0.96, squashTo: 1.03),
            Phase(duration: 0.26, frameKey: "happy", frame: 0,
                  fromX: 0.3, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.03, squashTo: 1),
        ])
    }

    private static func windowWatch() -> Behavior {
        Behavior(kind: .windowWatch, loopMs: 4400, phases: [
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: -2, toY: 0, ease: .easeInOut,
                  squashFrom: 1, squashTo: 1, stepping: 3, action: "walk"),
            Phase(duration: 0.26, frameKey: "idle", frame: 1,
                  fromX: -2, fromY: 0, toX: -2, toY: -0.4, ease: .easeOut,
                  squashFrom: 1, squashTo: 1.04, bubble: "?"),
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: -2, fromY: -0.4, toX: -1.5, toY: 0, ease: .easeInOut,
                  squashFrom: 1.04, squashTo: 0.96),
            Phase(duration: 0.26, frameKey: "idle", frame: 0,
                  fromX: -1.5, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.96, squashTo: 1, stepping: 3, action: "walk"),
        ])
    }

    private static func think() -> Behavior {
        let laptop = grounded(.laptop, centerX: 8, baseY: stageFloorY)
        return Behavior(kind: .think, loopMs: 4200, phases: [
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: -0.5, toY: 0.3, ease: .easeOut,
                  squashFrom: 0.98, squashTo: 1.02, props: [laptop]),
            Phase(duration: 0.26, frameKey: "idle", frame: 1,
                  fromX: -0.5, fromY: 0.3, toX: 0.5, toY: 0.3, ease: .easeInOut,
                  squashFrom: 1.02, squashTo: 0.98, props: [laptop], bubble: "…"),
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 0.5, fromY: 0.3, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1.02, props: [laptop], bubble: "!"),
            Phase(duration: 0.26, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1.02, squashTo: 1, props: [laptop], action: "work"),
        ])
    }

    private static func read() -> Behavior {
        let laptop = grounded(.laptopLit, centerX: 8, baseY: stageFloorY)
        return Behavior(kind: .read, loopMs: 4800, phases: [
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: -0.35, toY: 0.45, ease: .easeInOut,
                  squashFrom: 1, squashTo: 0.98, props: [laptop]),
            Phase(duration: 0.25, frameKey: "idle", frame: 1,
                  fromX: -0.35, fromY: 0.45, toX: 0.25, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1, props: [laptop]),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0.25, fromY: 0.4, toX: 0.4, toY: 0.45, ease: .easeInOut,
                  squashFrom: 1, squashTo: 0.98, props: [laptop], bubble: "…"),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0.4, fromY: 0.45, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1, props: [laptop]),
        ])
    }

    private static func multitask() -> Behavior {
        let left = grounded(.laptop, centerX: 5.2, baseY: stageFloorY)
        let right = grounded(.laptopLit, centerX: 10.8, baseY: stageFloorY)
        return Behavior(kind: .multitask, loopMs: 5000, phases: [
            Phase(duration: 0.2, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: -1.2, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1, squashTo: 0.97, props: [left, right], action: "work"),
            Phase(duration: 0.2, frameKey: "idle", frame: 1,
                  fromX: -1.2, fromY: 0.4, toX: 1.2, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 1, props: [left, right], bubble: "!"),
            Phase(duration: 0.2, frameKey: "idle", frame: 0,
                  fromX: 1.2, fromY: 0.4, toX: -0.8, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1, squashTo: 0.97, props: [left, right], action: "work"),
            Phase(duration: 0.2, frameKey: "idle", frame: 1,
                  fromX: -0.8, fromY: 0.4, toX: 0.8, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 1, props: [left, right], action: "work"),
            Phase(duration: 0.2, frameKey: "idle", frame: 0,
                  fromX: 0.8, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1, squashTo: 1, props: [left, right]),
        ])
    }

    private static func workBreak() -> Behavior {
        Behavior(kind: .workBreak, loopMs: 4400, phases: [
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: -1.1, ease: .easeOut,
                  squashFrom: 1, squashTo: 1.12),
            Phase(duration: 0.26, frameKey: "sleeping", frame: 0,
                  fromX: 0, fromY: -1.1, toX: 0, toY: -0.8, ease: .easeInOut,
                  squashFrom: 1.12, squashTo: 1.04, bubble: "…"),
            Phase(duration: 0.24, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: -0.8, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1.04, squashTo: 0.9),
            Phase(duration: 0.26, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0, ease: .easeOutBack,
                  squashFrom: 0.9, squashTo: 1),
        ])
    }

    private static func proud() -> Behavior {
        Behavior(kind: .proud, loopMs: 3200, phases: [
            Phase(duration: 0.24, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: -1.4, ease: .easeOutBack,
                  squashFrom: 1, squashTo: 1.08, bubble: "!", action: "cheer"),
            Phase(duration: 0.26, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: -1.4, toX: 0.7, toY: -0.8, ease: .easeInOut,
                  squashFrom: 1.08, squashTo: 0.96,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 2, seed: 0xF01)], action: "wave"),
            Phase(duration: 0.24, frameKey: "happy", frame: 0,
                  fromX: 0.7, fromY: -0.8, toX: -0.4, toY: 0, ease: .easeInOut,
                  squashFrom: 0.96, squashTo: 1.04, action: "wave"),
            Phase(duration: 0.26, frameKey: "idle", frame: 0,
                  fromX: -0.4, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.04, squashTo: 1),
        ])
    }

    private static func permissionWait() -> Behavior {
        let laptop = grounded(.laptop, centerX: 8, baseY: stageFloorY)
        return Behavior(kind: .permissionWait, loopMs: 4800, phases: [
            Phase(duration: 0.22, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.2, ease: .easeOut,
                  squashFrom: 0.98, squashTo: 1.04, props: [laptop], bubble: "!"),
            Phase(duration: 0.26, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: 0.2, toX: 1.1, toY: -0.4, ease: .easeInOut,
                  squashFrom: 1.04, squashTo: 0.96, props: [laptop], action: "wave"),
            Phase(duration: 0.24, frameKey: "happy", frame: 0,
                  fromX: 1.1, fromY: -0.4, toX: 0.5, toY: 0, ease: .easeOutBack,
                  squashFrom: 0.96, squashTo: 1.04, props: [laptop], bubble: "?", action: "wave"),
            Phase(duration: 0.28, frameKey: "idle", frame: 0,
                  fromX: 0.5, fromY: 0, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1.04, squashTo: 0.98, props: [laptop]),
        ])
    }

    private static func fidgetEarScratch() -> Behavior {
        Behavior(kind: .idle, loopMs: fidgetLoopMs, phases: [
            Phase(duration: 0.15, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: 0, toX: 0.3, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.98),
            Phase(duration: 0.15, frameKey: "idle", frame: 0,
                  fromX: 0.3, fromY: 0, toX: -0.3, toY: 0, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1.0),
            Phase(duration: 0.15, frameKey: "idle", frame: 1,
                  fromX: -0.3, fromY: 0, toX: 0.3, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.98),
            Phase(duration: 0.15, frameKey: "idle", frame: 0,
                  fromX: 0.3, fromY: 0, toX: -0.3, toY: 0, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1.0),
            Phase(duration: 0.40, frameKey: "idle", frame: 0,
                  fromX: -0.3, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0),
        ])
    }

    private static func fidgetLookLeft() -> Behavior {
        Behavior(kind: .idle, loopMs: fidgetLoopMs, phases: [
            Phase(duration: 0.22, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: -1.2, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0),
            Phase(duration: 0.30, frameKey: "idle", frame: 0,
                  fromX: -1.2, fromY: 0, toX: -1.2, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.98),
            Phase(duration: 0.22, frameKey: "idle", frame: 1,
                  fromX: -1.2, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1.0),
            Phase(duration: 0.26, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0),
        ])
    }

    private static func fidgetLookRight() -> Behavior {
        Behavior(kind: .idle, loopMs: fidgetLoopMs, phases: [
            Phase(duration: 0.22, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 1.2, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0),
            Phase(duration: 0.30, frameKey: "idle", frame: 0,
                  fromX: 1.2, fromY: 0, toX: 1.2, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.98),
            Phase(duration: 0.22, frameKey: "idle", frame: 1,
                  fromX: 1.2, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 1.0),
            Phase(duration: 0.26, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0),
        ])
    }

    private static func fidgetBlinkHold() -> Behavior {
        Behavior(kind: .idle, loopMs: fidgetLoopMs, phases: [
            Phase(duration: 0.34, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0),
            Phase(duration: 0.10, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.90),
            Phase(duration: 0.10, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.90, squashTo: 1.0),
            Phase(duration: 0.46, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0),
        ])
    }

    private static func fidgetStretch() -> Behavior {
        Behavior(kind: .idle, loopMs: fidgetLoopMs, phases: [
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: -1.0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.10),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: -1.0, toX: 0, toY: -1.0, ease: .easeInOut,
                  squashFrom: 1.10, squashTo: 1.08),
            Phase(duration: 0.25, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: -1.0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.08, squashTo: 0.95),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.95, squashTo: 1.0),
        ])
    }

    private static func stroll() -> Behavior {
        Behavior(kind: .stroll, loopMs: 5600, phases: [
            Phase(duration: 0.28, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 2.6, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0, stepping: 4, action: "walk"),
            Phase(duration: 0.16, frameKey: "idle", frame: 0,
                  fromX: 2.6, fromY: 0, toX: 2.6, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.94, bubble: "?"),
            Phase(duration: 0.30, frameKey: "idle", frame: 0,
                  fromX: 2.6, fromY: 0, toX: -2.2, toY: 0, ease: .easeInOut,
                  squashFrom: 0.94, squashTo: 1.0, stepping: 4, action: "walk"),
            Phase(duration: 0.12, frameKey: "idle", frame: 0,
                  fromX: -2.2, fromY: 0, toX: -2.2, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0),
            Phase(duration: 0.14, frameKey: "idle", frame: 0,
                  fromX: -2.2, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0, stepping: 2, action: "walk"),
        ])
    }

    /// Places a prop by its centre line and the stage floor rather than its
    /// top-left corner, so resizing the art keeps it planted and centred.
    static func grounded(_ sprite: PropSprite, centerX: Double, baseY: Double) -> PropInstance {
        let s = PixelProps.size(sprite)
        return PropInstance(sprite: sprite, x: centerX - s.width / 2, y: baseY - s.height, front: true)
    }

    private static func work() -> Behavior {
        let laptop = grounded(.laptop, centerX: 8, baseY: 16.5)
        let spark = { (seed: UInt64) in
            Emit(kind: .keystrokeSparks, localX: 8, localY: 11, count: 3, seed: seed)
        }
        return Behavior(kind: .work, loopMs: 3840, phases: [
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.97, props: [laptop], emits: [spark(0xA1)],
                  action: "work"),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 1.0, props: [laptop], emits: [spark(0xB2)],
                  action: "work"),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.97, props: [laptop], emits: [spark(0xC3)],
                  action: "work"),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 1.0, props: [laptop], action: "work"),
        ])
    }

    private static func celebrate(boosted: Bool) -> Behavior {
        let m = boosted ? 2 : 1
        let heart = boosted ? "♥♥♥" : "♥"
        return Behavior(kind: .celebrate, loopMs: 4160, phases: [
            Phase(duration: 0.14, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0, bubble: "!!"),
            Phase(duration: 0.14, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: 0, toX: 0, toY: 0.7, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.78),
            Phase(duration: 0.22, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0.7, toX: 0, toY: -3.2, ease: .easeOutBack,
                  squashFrom: 0.82, squashTo: 1.18,
                  emits: [Emit(kind: .confettiFall, localX: 8, localY: 0, count: 22 * m, seed: 0xCF),
                          Emit(kind: .confettiFall, localX: 4, localY: 2, count: 10 * m, seed: 0xC7)],
                  action: "cheer"),
            Phase(duration: 0.24, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: -3.2, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.18, squashTo: 0.9,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 4 * m, seed: 0x40)],
                  action: "cheer"),
            Phase(duration: 0.26, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.9, squashTo: 1.0, stepping: 2, bubble: heart, action: "cheer"),
        ])
    }

    private static func eat(tokens: Int64) -> Behavior {
        let full = foodSize(tokens: tokens)
        let bite1: PropSprite = full == .foodL ? .foodM : .foodS
        let bite2: PropSprite = .foodS
        func food(_ s: PropSprite) -> PropInstance {
            grounded(s, centerX: 9.6, baseY: 16.4)
        }
        let crumb1 = Emit(kind: .crumbBurst, localX: 9.6, localY: 13, count: 6, seed: 0xE1)
        let crumb2 = Emit(kind: .crumbBurst, localX: 9.6, localY: 13, count: 6, seed: 0xE2)
        // Every phase edge is a whole number of chews, so each tier drops on the
        // beat the jaw shuts.
        return Behavior(kind: .eat, loopMs: 4320, phases: [
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0.3, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0, props: [food(full)], bubble: "!", action: "eat"),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.7, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.88, props: [food(bite1)], emits: [crumb1],
                  action: "eat"),
            Phase(duration: 0.125, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.7, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.88, squashTo: 1.0, props: [food(bite1)], action: "eat"),
            Phase(duration: 0.25, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.7, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.88, props: [food(bite2)], emits: [crumb2],
                  bubble: "♥", action: "eat"),
            Phase(duration: 0.125, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0.7, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.88, squashTo: 1.0,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 3, seed: 0xE3)]),
        ])
    }

    private static func greet(boosted: Bool) -> Behavior {
        let m = boosted ? 2 : 1
        let heart = boosted ? "♥♥♥" : "♥"
        return Behavior(kind: .greet, loopMs: 2400, phases: [
            Phase(duration: 0.18, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.12, bubble: heart, action: "wave"),
            Phase(duration: 0.30, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: -2.2, ease: .easeOut,
                  squashFrom: 1.12, squashTo: 0.94,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 3 * m, seed: 0x9A)],
                  action: "wave"),
            Phase(duration: 0.22, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: -2.2, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.94, squashTo: 1.06, action: "wave"),
            Phase(duration: 0.30, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.06, squashTo: 1.0, stepping: 2, action: "wave"),
        ])
    }

    private static func sickDroop() -> Behavior {
        Behavior(kind: .sickDroop, loopMs: 4000, phases: [
            Phase(duration: 0.34, frameKey: "sick", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0.7, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.92),
            Phase(duration: 0.20, frameKey: "sick", frame: 1,
                  fromX: 0, fromY: 0.7, toX: 0, toY: 0.7, ease: .easeInOut,
                  squashFrom: 0.92, squashTo: 0.94),
            Phase(duration: 0.24, frameKey: "sick", frame: 0,
                  fromX: 0, fromY: 0.7, toX: 0, toY: 0.7, ease: .easeInOut,
                  squashFrom: 0.94, squashTo: 0.92),
            Phase(duration: 0.22, frameKey: "sick", frame: 0,
                  fromX: 0, fromY: 0.7, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.92, squashTo: 1.0),
        ])
    }

    /// Breathing lives in the art now (one slow rise/fall per 900ms), so the body
    /// squash stays almost flat and only the Zs keep their own drift.
    private static func nap() -> Behavior {
        Behavior(kind: .nap, loopMs: 5400, phases: [
            Phase(duration: 0.40, frameKey: "sleeping", frame: 0,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.99,
                  emits: [Emit(kind: .zDrift, localX: 10, localY: 1, count: 1, seed: 0x21)],
                  action: "nap"),
            Phase(duration: 0.30, frameKey: "sleeping", frame: 1,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 0.99, squashTo: 1.0,
                  emits: [Emit(kind: .zDrift, localX: 10, localY: 1, count: 1, seed: 0x22)],
                  action: "nap"),
            Phase(duration: 0.30, frameKey: "sleeping", frame: 0,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0,
                  emits: [Emit(kind: .zDrift, localX: 10, localY: 1, count: 1, seed: 0x23)],
                  action: "nap"),
        ])
    }

    private static func dizzy() -> Behavior {
        Behavior(kind: .dizzy, loopMs: 2000, phases: [
            Phase(duration: 0.20, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: 0, toX: 0.6, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.86, bubble: "@_@"),
            Phase(duration: 0.20, frameKey: "idle", frame: 0,
                  fromX: 0.6, fromY: 0, toX: -0.6, toY: 0, ease: .easeInOut,
                  squashFrom: 0.86, squashTo: 0.90, bubble: "@_@"),
            Phase(duration: 0.20, frameKey: "idle", frame: 1,
                  fromX: -0.6, fromY: 0, toX: 0.6, toY: 0, ease: .easeInOut,
                  squashFrom: 0.90, squashTo: 0.84, bubble: "@_@"),
            Phase(duration: 0.18, frameKey: "idle", frame: 0,
                  fromX: 0.6, fromY: 0, toX: -0.2, toY: 0, ease: .easeOutBack,
                  squashFrom: 0.84, squashTo: 1.08, bubble: "@_@"),
            Phase(duration: 0.22, frameKey: "idle", frame: 0,
                  fromX: -0.2, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.08, squashTo: 1.0),
        ])
    }

    private static func beg() -> Behavior {
        Behavior(kind: .beg, loopMs: 5040, phases: [
            Phase(duration: 0.24, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 2.0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0, stepping: 4, action: "walk"),
            Phase(duration: 0.16, frameKey: "idle", frame: 0,
                  fromX: 2.0, fromY: 0, toX: 2.0, toY: 0.9, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.90, bubble: "food?"),
            Phase(duration: 0.14, frameKey: "idle", frame: 1,
                  fromX: 2.0, fromY: 0.9, toX: 2.0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.90, squashTo: 1.0),
            Phase(duration: 0.16, frameKey: "idle", frame: 0,
                  fromX: 2.0, fromY: 0, toX: 2.0, toY: 0.9, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.90, bubble: "food?"),
            Phase(duration: 0.30, frameKey: "idle", frame: 0,
                  fromX: 2.0, fromY: 0.9, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.90, squashTo: 1.0, stepping: 4, action: "walk"),
        ])
    }

    private static func attention() -> Behavior {
        Behavior(kind: .attention, loopMs: 4500, phases: [
            Phase(duration: 0.16, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0.4, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.92, bubble: "?"),
            Phase(duration: 0.22, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: -2.4, ease: .easeOut,
                  squashFrom: 0.92, squashTo: 1.05, bubble: "?"),
            Phase(duration: 0.16, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: -2.4, toX: 0.5, toY: -2.4, ease: .easeInOut,
                  squashFrom: 1.05, squashTo: 1.0, bubble: "?"),
            Phase(duration: 0.16, frameKey: "happy", frame: 0,
                  fromX: 0.5, fromY: -2.4, toX: 0, toY: -2.4, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.02, bubble: "?"),
            Phase(duration: 0.30, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: -2.4, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.02, squashTo: 1.0, stepping: 2),
        ])
    }

    private static func petting() -> Behavior {
        Behavior(kind: .petting, loopMs: 2640, phases: [
            Phase(duration: 0.16, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.99,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 1, seed: 0xB0)], action: "petting"),
            Phase(duration: 0.16, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.99, squashTo: 0.97,
                  emits: [Emit(kind: .heartRise, localX: 6, localY: 1, count: 1, seed: 0xB1)], action: "petting"),
            Phase(duration: 0.18, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 0.98,
                  emits: [Emit(kind: .heartRise, localX: 10, localY: 1, count: 1, seed: 0xB2)], action: "petting"),
            Phase(duration: 0.16, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.98, squashTo: 0.97,
                  emits: [Emit(kind: .heartRise, localX: 7, localY: 1, count: 1, seed: 0xB3)], action: "petting"),
            Phase(duration: 0.16, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 0.99,
                  emits: [Emit(kind: .heartRise, localX: 9, localY: 1, count: 1, seed: 0xB4)], action: "petting"),
            Phase(duration: 0.18, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.99, squashTo: 1.0,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 1, seed: 0xB5)], action: "petting"),
        ])
    }
}
