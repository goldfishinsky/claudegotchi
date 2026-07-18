import XCTest
@testable import PetCore

final class EventApplierTests: XCTestCase {
    var applier: EventApplier!
    let cfg = ConfigYAML.defaults

    override func setUp() {
        applier = EventApplier(config: cfg)
    }

    private func evt(_ type: Event.EventType, sessionId: String? = nil, tool: String? = nil,
                     tokensIn: Int? = nil, tokensOut: Int? = nil, ts: Int64 = 0) -> Event {
        Event(
            schemaVersion: 1, eventId: UUID().uuidString, ts: ts, type: type,
            sessionId: sessionId, tool: tool, tokensIn: tokensIn, tokensOut: tokensOut, model: nil
        )
    }

    func testPostToolUseIncreasesFullnessAndXP() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 50
        let before = pet.fullness
        let next = applier.apply(event: evt(.postToolUse, tokensIn: 1000, tokensOut: 1000), to: pet)
        XCTAssertEqual(next.fullness, before + 1, accuracy: 1e-9)
        XCTAssertEqual(next.xp, 10)
    }

    func testPostToolUseFullnessCappedAt5() {
        let pet = Pet.fresh(species: "frog", at: 0)
        let next = applier.apply(event: evt(.postToolUse, tokensIn: 100_000, tokensOut: 100_000), to: pet)
        XCTAssertEqual(next.fullness, min(100, pet.fullness + 5), accuracy: 1e-9)
    }

    func testPostToolUseFullnessClampsTo100() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 99
        let next = applier.apply(event: evt(.postToolUse, tokensIn: 5000, tokensOut: 5000), to: pet)
        XCTAssertEqual(next.fullness, 100)
    }

    func testUserPromptSubmitLeavesPetUntouched() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 40; pet.stamina = 60; pet.intimacy = 70; pet.xp = 12
        let next = applier.apply(event: evt(.userPromptSubmit, sessionId: "s1", ts: 5), to: pet)
        XCTAssertEqual(next.fullness, 40, accuracy: 1e-9)
        XCTAssertEqual(next.stamina, 60, accuracy: 1e-9)
        XCTAssertEqual(next.intimacy, 70, accuracy: 1e-9)
        XCTAssertEqual(next.xp, 12)
    }

    func testPreToolUseDrainsStamina() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 50
        let next = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 0), to: pet)
        XCTAssertEqual(next.stamina, 49.5, accuracy: 1e-9)
    }

    func testStopAddsIntimacy() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 10
        let next = applier.apply(event: evt(.stop), to: pet)
        XCTAssertEqual(next.intimacy, 10.5, accuracy: 1e-9)
    }

    func testStopWithTokensFeedsFullnessAndXP() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 50; pet.intimacy = 10
        let next = applier.apply(event: evt(.stop, tokensIn: 1000, tokensOut: 1000), to: pet)
        XCTAssertEqual(next.fullness, 51, accuracy: 1e-9, "turn tokens now feed fullness on stop")
        XCTAssertEqual(next.xp, 10)
        XCTAssertEqual(next.intimacy, 10.5, accuracy: 1e-9, "intimacy bump preserved")
    }

    func testStopWithoutTokensLeavesFullnessAndXP() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 50
        let next = applier.apply(event: evt(.stop), to: pet)
        XCTAssertEqual(next.fullness, 50, accuracy: 1e-9)
        XCTAssertEqual(next.xp, 0)
    }

    func testSessionStartClearsHibernation() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.hibernationSince = 100
        let next = applier.apply(event: evt(.sessionStart, ts: 1_000_000), to: pet)
        XCTAssertNil(next.hibernationSince)
    }

    func testPreToolUsePendingResolvedByPostToolUse() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 0), to: pet)
        XCTAssertEqual(applier.pendingCount, 1)
        pet = applier.apply(event: evt(.postToolUse, sessionId: "s1", tool: "Bash", tokensIn: 1000, tokensOut: 0, ts: 1000), to: pet)
        XCTAssertEqual(applier.pendingCount, 0)
    }

    func testPendingTimeoutDropsAfter5Min() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 0), to: pet)
        XCTAssertEqual(applier.pendingCount, 1)
        applier.tickPendingTimeouts(nowMs: 5 * 60 * 1000 + 1)
        XCTAssertEqual(applier.pendingCount, 0)
    }

    func testSustainedSessionDoublesPreToolCost() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 50
        pet = applier.apply(event: evt(.sessionStart, sessionId: "s1", ts: 0), to: pet)
        pet = applier.apply(event: evt(.preToolUse, sessionId: "s1", tool: "Bash", ts: 1_860_000), to: pet)
        XCTAssertEqual(pet.stamina, 49, accuracy: 1e-9)
    }

    func testHibernateStartSetsField() {
        let pet = Pet.fresh(species: "frog", at: 0)
        let next = applier.apply(event: evt(.hibernateStart, ts: 5000), to: pet)
        XCTAssertEqual(next.hibernationSince, 5000)
    }

    func testPrApprovedRaisesIntimacy() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 40
        let next = applier.apply(event: evt(.prApproved), to: pet)
        XCTAssertEqual(next.intimacy, 40 + cfg.work.prApprovedIntimacy, accuracy: 1e-9)
    }

    func testPrApprovedIntimacyClampsTo100() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 99.5
        let next = applier.apply(event: evt(.prApproved), to: pet)
        XCTAssertEqual(next.intimacy, 100)
    }

    func testPrApprovedRepeatedApplyStaysClamped() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 100
        let a = applier.apply(event: evt(.prApproved), to: pet)
        let b = applier.apply(event: evt(.prApproved), to: a)
        XCTAssertEqual(a.intimacy, 100)
        XCTAssertEqual(b.intimacy, 100)
    }

    func testPrMergedAddsXpAndLeavesStatsUntouched() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 30; pet.stamina = 30; pet.intimacy = 30
        let next = applier.apply(event: evt(.prMerged), to: pet)
        XCTAssertEqual(next.xp, cfg.work.prMergedXp)
        XCTAssertEqual(next.fullness, 30, accuracy: 1e-9)
        XCTAssertEqual(next.stamina, 30, accuracy: 1e-9)
        XCTAssertEqual(next.intimacy, 30, accuracy: 1e-9)
    }

    func testPetClickAddsIntimacyClamped() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 10
        let next = applier.apply(event: evt(.petClick), to: pet)
        XCTAssertEqual(next.intimacy, 10 + cfg.eventCosts.petClickIntimacy, accuracy: 1e-9)
    }

    func testPetClickClampsAt100() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 99.5
        let next = applier.apply(event: evt(.petClick), to: pet)
        XCTAssertEqual(next.intimacy, 100)
    }

    func testSessionStartWakeReanchorsLastTickAt() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.hibernationSince = 100
        pet.lastTickAt = 100
        let next = applier.apply(event: evt(.sessionStart, ts: 5_000_000), to: pet)
        XCTAssertNil(next.hibernationSince)
        XCTAssertEqual(next.lastTickAt, 5_000_000, "wake re-anchors lastTickAt to event.ts")
    }

    func testSessionStartWhenAwakeDoesNotReanchor() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.hibernationSince = nil
        pet.lastTickAt = 100
        let next = applier.apply(event: evt(.sessionStart, ts: 5_000_000), to: pet)
        XCTAssertEqual(next.lastTickAt, 100, "no wake → lastTickAt untouched")
    }
}
