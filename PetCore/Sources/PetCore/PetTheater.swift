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

    public init(
        workingAgentCount: Int = 0,
        recentTokenDrop: TokenDrop? = nil,
        prCelebration: Bool = false,
        idleSeconds: Double = 0,
        hibernating: Bool = false,
        sick: Bool = false,
        hungry: Bool = false,
        memPressureHigh: Bool = false,
        recentClickAgeMs: Int64? = nil
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

public enum TheaterBehavior: String, Equatable, CaseIterable {
    case celebrate, eat, greet, work, sickDroop, stroll, idle, nap
}

// MARK: - particles

public enum ParticleKind: String, Equatable {
    case heartRise, confettiFall, keystrokeSparks, zDrift, crumbBurst
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

    public static func selectBehavior(_ s: TheaterSignals) -> TheaterBehavior {
        if s.prCelebration { return .celebrate }
        if let d = s.recentTokenDrop, d.ageMs <= eatWindowMs, d.tokens >= eatMinTokens { return .eat }
        if let c = s.recentClickAgeMs, c <= greetWindowMs { return .greet }
        if s.workingAgentCount > 0 { return .work }
        if s.sick { return .sickDroop }
        if s.hibernating { return .nap }
        if s.idleSeconds >= strollAfterSeconds, s.idleSeconds <= strollUntilSeconds { return .stroll }
        return .idle
    }

    public static func loopMs(_ k: TheaterBehavior, signals: TheaterSignals = TheaterSignals()) -> Int64 {
        behavior(k, signals: signals).loopMs
    }

    public static func foodSize(tokens: Int64) -> PropSprite {
        if tokens >= 8_000 { return .foodL }
        if tokens >= 2_000 { return .foodM }
        return .foodS
    }

    public static func scene(signals: TheaterSignals, timeMs: Int64) -> SceneFrame {
        let kind = selectBehavior(signals)
        let b = behavior(kind, signals: signals)
        let loop = b.loopMs
        let loopPos = ((timeMs % loop) + loop) % loop
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

        var offX = lerp(phase.fromX, phase.toX, e)
        var offY = lerp(phase.fromY, phase.toY, e)
        var frame = phase.frame
        if phase.stepping > 0 {
            let s = Double(phase.stepping)
            frame = Int(localT * s) % 2
            offY -= abs(sin(localT * s * .pi)) * 0.5
        }
        let squash = lerp(phase.squashFrom, phase.squashTo, e)

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

        return SceneFrame(
            behavior: kind, phaseIndex: pIndex,
            petOffsetX: offX, petOffsetY: offY, squash: squash,
            frameKey: phase.frameKey, frame: frame,
            props: phase.props, emissions: emissions, bubble: bubble
        )
    }

    // MARK: behaviour catalogue

    static func behavior(_ k: TheaterBehavior, signals: TheaterSignals) -> Behavior {
        switch k {
        case .idle: return idle()
        case .stroll: return stroll()
        case .work: return work()
        case .celebrate: return celebrate()
        case .eat: return eat(tokens: signals.recentTokenDrop?.tokens ?? 0)
        case .greet: return greet()
        case .sickDroop: return sickDroop()
        case .nap: return nap()
        }
    }

    private static func idle() -> Behavior {
        Behavior(kind: .idle, loopMs: 4000, phases: [
            Phase(duration: 0.30, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.95),
            Phase(duration: 0.30, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.95, squashTo: 1.0),
            Phase(duration: 0.22, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0.5, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0),
            Phase(duration: 0.18, frameKey: "idle", frame: 0,
                  fromX: 0.5, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0),
        ])
    }

    private static func stroll() -> Behavior {
        Behavior(kind: .stroll, loopMs: 6000, phases: [
            Phase(duration: 0.28, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 2.6, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0, stepping: 4),
            Phase(duration: 0.16, frameKey: "idle", frame: 0,
                  fromX: 2.6, fromY: 0, toX: 2.6, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.94, bubble: "?"),
            Phase(duration: 0.30, frameKey: "idle", frame: 0,
                  fromX: 2.6, fromY: 0, toX: -2.2, toY: 0, ease: .easeInOut,
                  squashFrom: 0.94, squashTo: 1.0, stepping: 4),
            Phase(duration: 0.12, frameKey: "idle", frame: 0,
                  fromX: -2.2, fromY: 0, toX: -2.2, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0),
            Phase(duration: 0.14, frameKey: "idle", frame: 0,
                  fromX: -2.2, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0, stepping: 2),
        ])
    }

    private static func work() -> Behavior {
        let laptop = PropInstance(sprite: .laptop, x: 2.5, y: 10.0, front: true)
        let spark = { (seed: UInt64) in
            Emit(kind: .keystrokeSparks, localX: 8, localY: 8, count: 3, seed: seed)
        }
        return Behavior(kind: .work, loopMs: 3200, phases: [
            Phase(duration: 0.26, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.97, props: [laptop], emits: [spark(0xA1)]),
            Phase(duration: 0.26, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 1.0, props: [laptop], emits: [spark(0xB2)]),
            Phase(duration: 0.26, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.97, props: [laptop], emits: [spark(0xC3)]),
            Phase(duration: 0.22, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 1.0, props: [laptop]),
        ])
    }

    private static func celebrate() -> Behavior {
        Behavior(kind: .celebrate, loopMs: 4200, phases: [
            Phase(duration: 0.14, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0, bubble: "!!"),
            Phase(duration: 0.14, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: 0, toX: 0, toY: 0.7, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.78),
            Phase(duration: 0.22, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0.7, toX: 0, toY: -3.2, ease: .easeOutBack,
                  squashFrom: 0.82, squashTo: 1.18,
                  emits: [Emit(kind: .confettiFall, localX: 8, localY: 0, count: 22, seed: 0xCF),
                          Emit(kind: .confettiFall, localX: 4, localY: 2, count: 10, seed: 0xC7)]),
            Phase(duration: 0.24, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: -3.2, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.18, squashTo: 0.9,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 4, seed: 0x40)]),
            Phase(duration: 0.26, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.9, squashTo: 1.0, stepping: 2, bubble: "♥"),
        ])
    }

    private static func eat(tokens: Int64) -> Behavior {
        let full = foodSize(tokens: tokens)
        let bite1: PropSprite = full == .foodL ? .foodM : .foodS
        let bite2: PropSprite = .foodS
        let foodX = 5.0, foodY = 9.0
        func food(_ s: PropSprite) -> PropInstance {
            PropInstance(sprite: s, x: foodX, y: foodY, front: true)
        }
        let crumb1 = Emit(kind: .crumbBurst, localX: 8, localY: 10, count: 6, seed: 0xE1)
        let crumb2 = Emit(kind: .crumbBurst, localX: 8, localY: 10, count: 6, seed: 0xE2)
        return Behavior(kind: .eat, loopMs: 4600, phases: [
            Phase(duration: 0.14, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0.3, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.0, props: [food(full)], bubble: "!"),
            Phase(duration: 0.18, frameKey: "idle", frame: 1,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.9, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.82, props: [food(bite1)], emits: [crumb1]),
            Phase(duration: 0.14, frameKey: "idle", frame: 0,
                  fromX: 0, fromY: 0.9, toX: 0, toY: 0.4, ease: .easeInOut,
                  squashFrom: 0.82, squashTo: 1.0, props: [food(bite1)]),
            Phase(duration: 0.18, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: 0.4, toX: 0, toY: 0.9, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 0.82, props: [food(bite2)], emits: [crumb2], bubble: "♥"),
            Phase(duration: 0.14, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0.9, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 0.82, squashTo: 1.0),
            Phase(duration: 0.22, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 3, seed: 0xE3)]),
        ])
    }

    private static func greet() -> Behavior {
        Behavior(kind: .greet, loopMs: 2600, phases: [
            Phase(duration: 0.18, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeOut,
                  squashFrom: 1.0, squashTo: 1.12, bubble: "♥"),
            Phase(duration: 0.30, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: -2.2, ease: .easeOut,
                  squashFrom: 1.12, squashTo: 0.94,
                  emits: [Emit(kind: .heartRise, localX: 8, localY: 1, count: 3, seed: 0x9A)]),
            Phase(duration: 0.22, frameKey: "happy", frame: 1,
                  fromX: 0, fromY: -2.2, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 0.94, squashTo: 1.06),
            Phase(duration: 0.30, frameKey: "happy", frame: 0,
                  fromX: 0, fromY: 0, toX: 0, toY: 0, ease: .easeInOut,
                  squashFrom: 1.06, squashTo: 1.0, stepping: 2),
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

    private static func nap() -> Behavior {
        Behavior(kind: .nap, loopMs: 5200, phases: [
            Phase(duration: 0.40, frameKey: "sleeping", frame: 0,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 0.97,
                  emits: [Emit(kind: .zDrift, localX: 10, localY: 1, count: 1, seed: 0x21)]),
            Phase(duration: 0.30, frameKey: "sleeping", frame: 1,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 0.97, squashTo: 1.0,
                  emits: [Emit(kind: .zDrift, localX: 10, localY: 1, count: 1, seed: 0x22)]),
            Phase(duration: 0.30, frameKey: "sleeping", frame: 0,
                  fromX: 0, fromY: 0.3, toX: 0, toY: 0.3, ease: .easeInOut,
                  squashFrom: 1.0, squashTo: 1.0,
                  emits: [Emit(kind: .zDrift, localX: 10, localY: 1, count: 1, seed: 0x23)]),
        ])
    }
}
