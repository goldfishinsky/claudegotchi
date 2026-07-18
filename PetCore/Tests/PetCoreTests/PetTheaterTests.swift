import XCTest
@testable import PetCore

final class PetTheaterTests: XCTestCase {

    // MARK: behaviour selection & priority

    func testDefaultIsIdle() {
        XCTAssertEqual(PetTheater.selectBehavior(TheaterSignals()), .idle)
    }

    func testCelebrateBeatsEverything() {
        let s = TheaterSignals(
            workingAgentCount: 3,
            recentTokenDrop: TokenDrop(tokens: 9000, ageMs: 100),
            prCelebration: true,
            hibernating: true, sick: true,
            recentClickAgeMs: 100
        )
        XCTAssertEqual(PetTheater.selectBehavior(s), .celebrate)
    }

    func testEatBeatsGreetWorkSick() {
        let s = TheaterSignals(
            workingAgentCount: 2,
            recentTokenDrop: TokenDrop(tokens: 5000, ageMs: 1000),
            sick: true,
            recentClickAgeMs: 100
        )
        XCTAssertEqual(PetTheater.selectBehavior(s), .eat)
    }

    func testGreetBeatsWork() {
        let s = TheaterSignals(workingAgentCount: 1, recentClickAgeMs: 500)
        XCTAssertEqual(PetTheater.selectBehavior(s), .greet)
    }

    func testWorkBeatsSick() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(workingAgentCount: 1, sick: true)), .work)
    }

    func testSickBeatsNap() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(hibernating: true, sick: true)), .sickDroop)
    }

    func testHibernatingNapsWhenNoOtherSignal() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(hibernating: true)), .nap)
    }

    func testStrollWhenBored() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(idleSeconds: 40)), .stroll)
    }

    func testVeryLongIdleRestsCalmly() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(idleSeconds: 100_000)), .idle)
    }

    func testStaleTokenDropDoesNotTriggerEat() {
        let s = TheaterSignals(recentTokenDrop: TokenDrop(tokens: 9000, ageMs: 500_000))
        XCTAssertEqual(PetTheater.selectBehavior(s), .idle)
    }

    func testTinyTokenDropDoesNotTriggerEat() {
        let s = TheaterSignals(recentTokenDrop: TokenDrop(tokens: 50, ageMs: 100))
        XCTAssertEqual(PetTheater.selectBehavior(s), .idle)
    }

    func testStaleClickDoesNotGreet() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(recentClickAgeMs: 60_000)), .idle)
    }

    // MARK: food size scales with tokens

    func testFoodSizeScales() {
        XCTAssertEqual(PetTheater.foodSize(tokens: 300), .foodS)
        XCTAssertEqual(PetTheater.foodSize(tokens: 3000), .foodM)
        XCTAssertEqual(PetTheater.foodSize(tokens: 20000), .foodL)
    }

    func testEatShowsFoodPropScaledByTokens() {
        var sawLarge = false
        let s = TheaterSignals(recentTokenDrop: TokenDrop(tokens: 20000, ageMs: 100))
        for step in 0..<40 {
            let scene = PetTheater.scene(signals: s, timeMs: Int64(step) * 120)
            if scene.props.contains(where: { $0.sprite == .foodL }) { sawLarge = true }
        }
        XCTAssertTrue(sawLarge, "large token drop should show a bento")
    }

    // MARK: scene phase coverage & loop safety

    func testEveryBehaviorPhasesSumToOne() {
        for k in TheaterBehavior.allCases {
            let b = PetTheater.behavior(k, signals: TheaterSignals(
                recentTokenDrop: TokenDrop(tokens: 9000, ageMs: 0)))
            let total = b.phases.reduce(0) { $0 + $1.duration }
            XCTAssertEqual(total, 1.0, accuracy: 1e-9, "\(k) phases must sum to 1")
            XCTAssertGreaterThanOrEqual(b.phases.count, 3)
            XCTAssertLessThanOrEqual(b.phases.count, 6)
            XCTAssertGreaterThanOrEqual(b.loopMs, 2000)
            XCTAssertLessThanOrEqual(b.loopMs, 8000)
        }
    }

    func testLoopClosesSeamlessly() {
        // pet offset at t=0 must equal offset just before the loop wraps
        for k in TheaterBehavior.allCases {
            let b = PetTheater.behavior(k, signals: TheaterSignals(
                recentTokenDrop: TokenDrop(tokens: 5000, ageMs: 0)))
            let sig = signalsFor(k)
            let start = PetTheater.scene(signals: sig, timeMs: 0)
            let end = PetTheater.scene(signals: sig, timeMs: b.loopMs - 1)
            XCTAssertEqual(start.petOffsetX, end.petOffsetX, accuracy: 0.25, "\(k) x loop seam")
            XCTAssertEqual(start.petOffsetY, end.petOffsetY, accuracy: 0.25, "\(k) y loop seam")
            XCTAssertEqual(start.squash, end.squash, accuracy: 0.1, "\(k) squash loop seam")
        }
    }

    func testScenePhaseAdvancesOverTime() {
        let sig = TheaterSignals(workingAgentCount: 1)
        var seen = Set<Int>()
        let b = PetTheater.behavior(.work, signals: sig)
        for step in 0..<24 {
            let t = Int64(step) * (b.loopMs / 24)
            seen.insert(PetTheater.scene(signals: sig, timeMs: t).phaseIndex)
        }
        XCTAssertEqual(seen, Set(0..<b.phases.count), "all work phases visited across a loop")
    }

    func testOffsetStaysWithinEasedBounds() {
        // easeOutBack can overshoot but offsets must stay on-stage
        for k in TheaterBehavior.allCases {
            let sig = signalsFor(k)
            let b = PetTheater.behavior(k, signals: sig)
            for step in 0..<60 {
                let t = Int64(step) * (b.loopMs / 60)
                let scene = PetTheater.scene(signals: sig, timeMs: t)
                XCTAssertLessThanOrEqual(abs(scene.petOffsetX), 6, "\(k) x on-stage")
                XCTAssertLessThanOrEqual(abs(scene.petOffsetY), 5, "\(k) y on-stage")
                XCTAssertGreaterThan(scene.squash, 0.5)
                XCTAssertLessThan(scene.squash, 1.5)
            }
        }
    }

    func testCelebrateHasAnticipationThenJump() {
        // crouch (positive y) must precede the peak (most-negative y)
        let sig = TheaterSignals(prCelebration: true)
        let b = PetTheater.behavior(.celebrate, signals: sig)
        var crouchT: Int64 = -1
        var peakT: Int64 = -1
        var peakY = 0.0
        var maxCrouch = 0.0
        for step in 0..<80 {
            let t = Int64(step) * (b.loopMs / 80)
            let s = PetTheater.scene(signals: sig, timeMs: t)
            if s.petOffsetY > maxCrouch { maxCrouch = s.petOffsetY; crouchT = t }
            if s.petOffsetY < peakY { peakY = s.petOffsetY; peakT = t }
        }
        XCTAssertGreaterThan(maxCrouch, 0.3, "there is a crouch")
        XCTAssertLessThan(peakY, -2.0, "there is a real jump")
        XCTAssertLessThan(crouchT, peakT, "anticipation precedes the jump")
    }

    // MARK: particles

    func testParticlesAreDeterministic() {
        let e = ActiveEmission(kind: .confettiFall, originX: 8, originY: 0,
                               count: 12, seed: 0xABCD, ageMs: 400)
        XCTAssertEqual(ParticleSim.particles(e), ParticleSim.particles(e))
    }

    func testParticlesDieAfterLifetime() {
        let life = ParticleSim.lifetimeMs(.crumbBurst)
        let alive = ActiveEmission(kind: .crumbBurst, originX: 0, originY: 0,
                                   count: 6, seed: 1, ageMs: 10)
        XCTAssertFalse(ParticleSim.particles(alive).isEmpty)
        let dead = ActiveEmission(kind: .crumbBurst, originX: 0, originY: 0,
                                  count: 6, seed: 1, ageMs: life + 200)
        // beyond lifetime every particle has fully faded
        XCTAssertTrue(ParticleSim.particles(dead).allSatisfy { $0.alpha <= 0.001 })
    }

    func testHeartsRiseAndFade() {
        let young = ActiveEmission(kind: .heartRise, originX: 0, originY: 0,
                                   count: 4, seed: 7, ageMs: 200)
        let old = ActiveEmission(kind: .heartRise, originX: 0, originY: 0,
                                 count: 4, seed: 7, ageMs: 1100)
        let y0 = ParticleSim.particles(young).map(\.y).reduce(0, +)
        let y1 = ParticleSim.particles(old).map(\.y).reduce(0, +)
        XCTAssertLessThan(y1, y0, "hearts move up (smaller y) over time")
        let a0 = ParticleSim.particles(young).map(\.alpha).max() ?? 0
        let a1 = ParticleSim.particles(old).map(\.alpha).max() ?? 0
        XCTAssertGreaterThan(a0, a1, "hearts fade")
    }

    func testEmissionsReportPositiveAge() {
        let sig = TheaterSignals(workingAgentCount: 1)
        let b = PetTheater.behavior(.work, signals: sig)
        var sawSpark = false
        for step in 0..<40 {
            let t = Int64(step) * (b.loopMs / 40)
            let scene = PetTheater.scene(signals: sig, timeMs: t)
            for em in scene.emissions {
                XCTAssertGreaterThanOrEqual(em.ageMs, 0)
                XCTAssertLessThanOrEqual(em.ageMs, ParticleSim.lifetimeMs(em.kind))
                if em.kind == .keystrokeSparks { sawSpark = true }
            }
        }
        XCTAssertTrue(sawSpark, "work emits keystroke sparks")
    }

    // MARK: easing

    func testEasingEndpoints() {
        for e in [Easing.linear, .easeOut, .easeInOut, .easeOutBack] {
            XCTAssertEqual(e.apply(0), 0, accuracy: 1e-9)
            XCTAssertEqual(e.apply(1), 1, accuracy: 1e-9)
        }
    }

    func testEaseOutBackOvershoots() {
        XCTAssertGreaterThan(Easing.easeOutBack.apply(0.8), 1.0, "back easing overshoots past 1")
    }

    func testEaseInOutClamps() {
        XCTAssertEqual(Easing.easeInOut.apply(-1), 0)
        XCTAssertEqual(Easing.easeInOut.apply(2), 1)
    }

    // MARK: helpers

    private func signalsFor(_ k: TheaterBehavior) -> TheaterSignals {
        switch k {
        case .celebrate: return TheaterSignals(prCelebration: true)
        case .eat: return TheaterSignals(recentTokenDrop: TokenDrop(tokens: 9000, ageMs: 100))
        case .greet: return TheaterSignals(recentClickAgeMs: 200)
        case .work: return TheaterSignals(workingAgentCount: 1)
        case .sickDroop: return TheaterSignals(sick: true)
        case .nap: return TheaterSignals(hibernating: true)
        case .stroll: return TheaterSignals(idleSeconds: 40)
        case .idle: return TheaterSignals()
        }
    }
}
