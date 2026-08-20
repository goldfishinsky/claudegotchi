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
        // long idle but petted recently → no attention-seeking, just calm idle
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(idleSeconds: 100_000, recentClickAgeMs: 120_000)), .idle)
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
            let start = PetTheater.scene(behavior: k, signals: sig, actionTimeMs: 0)
            let end = PetTheater.scene(behavior: k, signals: sig, actionTimeMs: b.loopMs - 1)
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
                let scene = PetTheater.scene(behavior: k, signals: sig, actionTimeMs: t)
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

    // MARK: overlay tap-reaction channel

    func testTapReactionSquashDipsThenRecovers() {
        let dip = PetTheater.tapReactionSquash(ageMs: 60)!
        let peak = PetTheater.tapReactionSquash(ageMs: 200)!
        let settle = PetTheater.tapReactionSquash(ageMs: 399)!
        XCTAssertLessThan(dip, 0.95, "press-down squashes")
        XCTAssertGreaterThan(peak, 1.0, "spring-back overshoots")
        XCTAssertEqual(settle, 1.0, accuracy: 0.02, "settles to rest")
    }

    func testTapReactionSquashNilOutsideWindow() {
        XCTAssertNil(PetTheater.tapReactionSquash(ageMs: -1))
        XCTAssertNil(PetTheater.tapReactionSquash(ageMs: 400))
        XCTAssertNil(PetTheater.tapReactionSquash(ageMs: 5000))
    }

    func testBlockedTapAddsDimMoteAndBendsSquash() {
        let base = PetTheater.scene(signals: TheaterSignals(), timeMs: 1000)
        let tapped = PetTheater.scene(
            signals: TheaterSignals(lastTapAgeMs: 60, lastTapCounted: false), timeMs: 1000)
        XCTAssertTrue(tapped.emissions.contains { $0.kind == .tapDust }, "blocked tap puffs one mote")
        XCTAssertNotEqual(base.squash, tapped.squash, accuracy: 0.0001, "reaction bends the squash")
        XCTAssertNil(tapped.bubble, "no reward bubble on a blocked tap")
    }

    func testCountedTapSkipsOverlay() {
        let scene = PetTheater.scene(
            signals: TheaterSignals(lastTapAgeMs: 60, lastTapCounted: true), timeMs: 1000)
        XCTAssertFalse(scene.emissions.contains { $0.kind == .tapDust }, "counted tap is rewarded by greet, not the mote")
    }

    func testTapOverlaySuppressedDuringPetting() {
        let scene = PetTheater.scene(
            signals: TheaterSignals(pettingActive: true, lastTapAgeMs: 60, lastTapCounted: false),
            timeMs: 1000)
        XCTAssertEqual(scene.behavior, .petting)
        XCTAssertFalse(scene.emissions.contains { $0.kind == .tapDust })
    }

    func testTapDustFadesDim() {
        let e = ActiveEmission(kind: .tapDust, originX: 8, originY: 0, count: 1, seed: 1, ageMs: 40)
        let alpha = ParticleSim.particles(e).map(\.alpha).max() ?? 1
        XCTAssertLessThanOrEqual(alpha, 0.6, "the mote reads as a lesser, dim puff")
    }

    // MARK: combo-tap dizzy

    func testComboTapTriggersDizzy() {
        XCTAssertEqual(PetTheater.selectBehavior(TheaterSignals(comboTap: true)), .dizzy)
    }

    func testDizzyPreemptsGreetButNotEatOrCelebrate() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(recentClickAgeMs: 100, comboTap: true)), .dizzy)
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(recentTokenDrop: TokenDrop(tokens: 9000, ageMs: 100), comboTap: true)), .eat)
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(prCelebration: true, comboTap: true)), .celebrate)
    }

    func testDizzyShowsSpiralBubbleAndWobbles() {
        let sig = TheaterSignals(comboTap: true)
        let b = PetTheater.behavior(.dizzy, signals: sig)
        var sawBubble = false
        var minX = 0.0, maxX = 0.0
        for step in 0..<60 {
            let t = Int64(step) * (b.loopMs / 60)
            let s = PetTheater.scene(signals: sig, timeMs: t)
            if s.bubble == "@_@" { sawBubble = true }
            minX = min(minX, s.petOffsetX); maxX = max(maxX, s.petOffsetX)
        }
        XCTAssertTrue(sawBubble, "dizzy shows @_@")
        XCTAssertGreaterThan(maxX, 0.1, "wobbles right")
        XCTAssertLessThan(minX, -0.1, "wobbles left")
    }

    // MARK: idle fidget pool

    func testFidgetIndexIsDeterministic() {
        for b in Int64(0)..<200 {
            XCTAssertEqual(PetTheater.fidgetIndex(bucket: b), PetTheater.fidgetIndex(bucket: b))
        }
    }

    func testFidgetNeverRepeatsImmediately() {
        for b in Int64(1)..<1000 {
            XCTAssertNotEqual(
                PetTheater.fidgetIndex(bucket: b), PetTheater.fidgetIndex(bucket: b - 1),
                "bucket \(b) repeats its predecessor")
        }
    }

    func testFidgetCoversEveryVariant() {
        var seen = Set<Int>()
        for b in Int64(0)..<40 { seen.insert(PetTheater.fidgetIndex(bucket: b)) }
        XCTAssertEqual(seen, Set(0..<PetTheater.fidgetVariants), "all fidget variants appear")
    }

    func testEveryFidgetVariantSatisfiesInvariants() {
        for bucket in Int64(0)..<Int64(PetTheater.fidgetVariants) {
            let b = PetTheater.idleFidget(bucket: bucket)
            let total = b.phases.reduce(0) { $0 + $1.duration }
            XCTAssertEqual(total, 1.0, accuracy: 1e-9, "fidget \(bucket) phases must sum to 1")
            XCTAssertGreaterThanOrEqual(b.phases.count, 3)
            XCTAssertLessThanOrEqual(b.phases.count, 6)
            for step in 0..<60 {
                let t = Int64(step) * (b.loopMs / 60)
                let s = PetTheater.scene(signals: idleAt(bucket: bucket, step: step), timeMs: bucket * b.loopMs + t)
                XCTAssertLessThanOrEqual(abs(s.petOffsetX), 6)
                XCTAssertLessThanOrEqual(abs(s.petOffsetY), 5)
                XCTAssertGreaterThan(s.squash, 0.5)
                XCTAssertLessThan(s.squash, 1.5)
            }
        }
    }

    func testIdleActuallyRotatesFidgets() {
        // bucket 0 → ear-scratch (tiny x wobble); bucket 3 → look-left (reaches -1.2)
        var earMinX = 0.0, leftMinX = 0.0
        let loop = PetTheater.fidgetLoopMs
        for step in 0..<80 {
            let t0 = Int64(step) * (loop / 80)
            earMinX = min(earMinX, PetTheater.scene(signals: TheaterSignals(), timeMs: t0).petOffsetX)
            let t3 = 3 * loop + Int64(step) * (loop / 80)
            leftMinX = min(leftMinX, PetTheater.scene(signals: TheaterSignals(), timeMs: t3).petOffsetX)
        }
        XCTAssertGreaterThan(earMinX, -0.5, "ear-scratch barely drifts")
        XCTAssertLessThan(leftMinX, -1.0, "look-left leans far")
    }

    // MARK: tiered begging

    func testBegsWhenHungryTooLong() {
        XCTAssertEqual(PetTheater.selectBehavior(TheaterSignals(hungrySinceSeconds: 200)), .beg)
    }

    func testDoesNotBegBelowThreshold() {
        XCTAssertEqual(PetTheater.selectBehavior(TheaterSignals(hungrySinceSeconds: 60)), .idle)
    }

    func testSevereHungerStaysSickDroopNotBeg() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(sick: true, hungrySinceSeconds: 300)), .sickDroop)
    }

    func testWorkBeatsBeg() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(workingAgentCount: 1, hungrySinceSeconds: 300)), .work)
    }

    func testBegShowsFoodBubbleAndReturnsHome() {
        let sig = TheaterSignals(hungrySinceSeconds: 200)
        let b = PetTheater.behavior(.beg, signals: sig)
        var sawFood = false
        var maxX = 0.0
        for step in 0..<80 {
            let t = Int64(step) * (b.loopMs / 80)
            let s = PetTheater.scene(signals: sig, timeMs: t)
            if s.bubble == "food?" { sawFood = true }
            maxX = max(maxX, s.petOffsetX)
        }
        XCTAssertTrue(sawFood, "beg asks for food")
        XCTAssertGreaterThan(maxX, 1.0, "beg walks toward the food spot")
    }

    // MARK: attention seeking

    func testSeeksAttentionWhenIgnoredLong() {
        XCTAssertEqual(PetTheater.selectBehavior(TheaterSignals(idleSeconds: 300)), .attention)
    }

    func testNoAttentionIfPettedRecently() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(idleSeconds: 300, recentClickAgeMs: 120_000)), .idle)
    }

    func testNoAttentionWhenSickOrHibernating() {
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(idleSeconds: 300, sick: true)), .sickDroop)
        XCTAssertEqual(PetTheater.selectBehavior(
            TheaterSignals(idleSeconds: 300, hibernating: true)), .nap)
    }

    func testStrollWindowStillWinsBeforeAttention() {
        XCTAssertEqual(PetTheater.selectBehavior(TheaterSignals(idleSeconds: 100)), .stroll)
    }

    func testAttentionHoldsQuestionLongerThanStroll() {
        func questionFrames(_ k: TheaterBehavior) -> Int {
            let sig = signalsFor(k)
            let b = PetTheater.behavior(k, signals: sig)
            var count = 0
            for step in 0..<120 {
                let t = Int64(step) * (b.loopMs / 120)
                if PetTheater.scene(signals: sig, timeMs: t).bubble == "?" { count += 1 }
            }
            return count
        }
        XCTAssertGreaterThan(questionFrames(.attention), questionFrames(.stroll),
                             "attention lingers on its plea")
    }

    // MARK: high-intimacy variants

    func testHighIntimacyDoublesCelebrateParticles() {
        func maxConfetti(_ boosted: Bool) -> Int {
            let sig = TheaterSignals(prCelebration: true, intimacyHigh: boosted)
            let b = PetTheater.behavior(.celebrate, signals: sig)
            var m = 0
            for step in 0..<120 {
                let t = Int64(step) * (b.loopMs / 120)
                for e in PetTheater.scene(signals: sig, timeMs: t).emissions where e.kind == .confettiFall {
                    m = max(m, e.count)
                }
            }
            return m
        }
        XCTAssertEqual(maxConfetti(true), 2 * maxConfetti(false), "intimacy ≥80 doubles the confetti")
    }

    func testHighIntimacyGreetShowsTripleHeart() {
        func bubbles(_ boosted: Bool) -> Set<String> {
            let sig = TheaterSignals(recentClickAgeMs: 200, intimacyHigh: boosted)
            let b = PetTheater.behavior(.greet, signals: sig)
            var out = Set<String>()
            for step in 0..<80 {
                let t = Int64(step) * (b.loopMs / 80)
                if let bub = PetTheater.scene(signals: sig, timeMs: t).bubble { out.insert(bub) }
            }
            return out
        }
        XCTAssertTrue(bubbles(true).contains("♥♥♥"))
        XCTAssertTrue(bubbles(false).contains("♥"))
        XCTAssertFalse(bubbles(false).contains("♥♥♥"))
    }

    // MARK: petting

    func testPettingActiveSelectsPetting() {
        XCTAssertEqual(PetTheater.selectBehavior(TheaterSignals(pettingActive: true)), .petting)
    }

    func testPettingBeatsGreetWorkAndEat() {
        let s = TheaterSignals(
            workingAgentCount: 2,
            recentTokenDrop: TokenDrop(tokens: 9000, ageMs: 100),
            recentClickAgeMs: 100, pettingActive: true)
        XCTAssertEqual(PetTheater.selectBehavior(s), .petting)
    }

    func testPettingRisesHeartsGently() {
        let sig = TheaterSignals(pettingActive: true)
        let b = PetTheater.behavior(.petting, signals: sig)
        var sawHeart = false
        for step in 0..<60 {
            let t = Int64(step) * (b.loopMs / 60)
            let s = PetTheater.scene(signals: sig, timeMs: t)
            if s.emissions.contains(where: { $0.kind == .heartRise }) { sawHeart = true }
            XCTAssertGreaterThan(s.squash, 0.90, "petting stays gentle")
            XCTAssertLessThan(s.squash, 1.05)
        }
        XCTAssertTrue(sawHeart, "petting floats hearts")
    }

    // MARK: helpers

    private func idleAt(bucket: Int64, step: Int) -> TheaterSignals { TheaterSignals() }

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
        case .dizzy: return TheaterSignals(comboTap: true)
        case .beg: return TheaterSignals(hungrySinceSeconds: 200)
        case .attention: return TheaterSignals(idleSeconds: 300)
        case .petting: return TheaterSignals(pettingActive: true)
        default: return TheaterSignals()
        }
    }
}
