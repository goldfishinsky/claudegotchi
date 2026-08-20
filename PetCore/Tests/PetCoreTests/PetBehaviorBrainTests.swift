import XCTest
@testable import PetCore

final class PetBehaviorBrainTests: XCTestCase {
    private let seed: UInt64 = 0xC1A0_DE60

    func testDecisionPersistsUntilItsDurationEnds() {
        var brain = PetBehaviorBrain()
        let first = brain.decide(
            signals: TheaterSignals(), environment: PetEnvironment(), nowMs: 1_000,
            personality: .neutral, genomeSeed: seed)
        let middle = brain.decide(
            signals: TheaterSignals(), environment: PetEnvironment(),
            nowMs: 1_000 + first.durationMs - 1,
            personality: .neutral, genomeSeed: seed)
        XCTAssertEqual(first, middle)
    }

    func testRecentActionsDoNotImmediatelyRepeat() {
        var brain = PetBehaviorBrain()
        var now: Int64 = 10_000
        var decisions: [TheaterBehavior] = []
        for _ in 0..<12 {
            let d = brain.decide(
                signals: TheaterSignals(idleSeconds: 80), environment: PetEnvironment(),
                nowMs: now, personality: .neutral, genomeSeed: seed)
            decisions.append(d.behavior)
            now += d.durationMs + 1
        }
        for i in 1..<decisions.count {
            XCTAssertNotEqual(decisions[i], decisions[i - 1])
        }
    }

    func testCompletionAndTokenEventsAreConsumedOnce() {
        var brain = PetBehaviorBrain()
        let completion = TheaterSignals(prCelebration: true, celebrationEventID: 42)
        let first = brain.decide(
            signals: completion, environment: PetEnvironment(), nowMs: 1_000,
            personality: .neutral, genomeSeed: seed)
        XCTAssertTrue(first.behavior == .proud || first.behavior == .celebrate)
        let later = brain.decide(
            signals: completion, environment: PetEnvironment(),
            nowMs: first.startedAtMs + first.durationMs + 1,
            personality: .neutral, genomeSeed: seed)
        XCTAssertFalse(later.behavior == .proud || later.behavior == .celebrate)
    }

    func testDragInterruptsCurrentAmbientAction() {
        var brain = PetBehaviorBrain()
        let ambient = brain.decide(
            signals: TheaterSignals(), environment: PetEnvironment(), nowMs: 1_000,
            personality: .neutral, genomeSeed: seed)
        let landing = brain.decide(
            signals: TheaterSignals(),
            environment: PetEnvironment(isDesktop: true, dragEventID: 99),
            nowMs: 1_100, personality: .neutral, genomeSeed: seed)
        XCTAssertNotEqual(ambient.sequence, landing.sequence)
        XCTAssertEqual(landing.behavior, .landing)
    }

    func testPermissionRequestInterruptsAndHoldsWaitingBehavior() {
        var brain = PetBehaviorBrain()
        _ = brain.decide(
            signals: TheaterSignals(), environment: PetEnvironment(), nowMs: 1_000,
            personality: .neutral, genomeSeed: seed)
        let waiting = brain.decide(
            signals: TheaterSignals(permissionPending: true), environment: PetEnvironment(),
            nowMs: 1_100, personality: .neutral, genomeSeed: seed)
        XCTAssertEqual(waiting.behavior, .permissionWait)

        let held = brain.decide(
            signals: TheaterSignals(permissionPending: true), environment: PetEnvironment(),
            nowMs: 2_000, personality: .neutral, genomeSeed: seed)
        XCTAssertEqual(waiting, held)
    }

    func testWorkPoolContainsSeveralBehaviorsOverLongSession() {
        var brain = PetBehaviorBrain()
        var now: Int64 = 1_000
        var seen = Set<TheaterBehavior>()
        let signals = TheaterSignals(
            workingAgentCount: 3, activeTool: "Read", workingDurationSeconds: 2_000)
        for _ in 0..<30 {
            let d = brain.decide(
                signals: signals, environment: PetEnvironment(localHour: 14),
                nowMs: now, personality: .neutral, genomeSeed: seed)
            seen.insert(d.behavior)
            now += d.durationMs + 1
        }
        XCTAssertGreaterThanOrEqual(seen.count, 4)
        XCTAssertTrue(seen.contains(.work))
    }

    func testProfileLearnsBehaviorAffinityAndWorkRhythm() {
        var profile = PetBehaviorProfile()
        profile.reinforce(.groom, amount: 0.2)
        XCTAssertEqual(profile.affinity[TheaterBehavior.groom.rawValue] ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertTrue(profile.recordWorkHour(22, sampleKey: "2026-08-20-22"))
        XCTAssertFalse(profile.recordWorkHour(22, sampleKey: "2026-08-20-22"))
        XCTAssertGreaterThan(profile.workAffinity(hour: 22), profile.workAffinity(hour: 12))
    }
}
