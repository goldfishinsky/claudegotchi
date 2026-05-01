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
}
