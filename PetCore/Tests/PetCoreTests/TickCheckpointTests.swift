import XCTest
@testable import PetCore

final class TickCheckpointTests: XCTestCase {
    let cfg = ConfigYAML.defaults

    private func pet(lastTickAt: Int64, hibernating: Int64? = nil) -> Pet {
        var p = Pet.fresh(species: "frog", at: 0)
        p.fullness = 50; p.stamina = 50; p.intimacy = 50
        p.lastTickAt = lastTickAt
        p.hibernationSince = hibernating
        return p
    }

    func testClockSkewClampsNoDecay() {
        let p = pet(lastTickAt: 10_000)
        let r = TickCheckpoint.run(pet: p, nowMs: 5_000, lastEventMs: 10_000, config: cfg)
        XCTAssertEqual(r.pet.fullness, 50, "elapsed<0 → no decay")
        XCTAssertEqual(r.pet.lastTickAt, 5_000)
        XCTAssertNil(r.emit)
    }

    func testNormalDecayAwake() {
        let p = pet(lastTickAt: 0)
        let r = TickCheckpoint.run(pet: p, nowMs: 10_000, lastEventMs: 9_000, config: cfg)
        let expected = Decay.apply(pet: p, elapsedSeconds: 10.0, config: cfg).fullness
        XCTAssertEqual(r.pet.fullness, expected, accuracy: 1e-9)
        XCTAssertEqual(r.pet.lastTickAt, 10_000)
        XCTAssertNil(r.emit)
    }

    func testHibernateEnterBoundaryEmitsAndSkipsDecay() {
        let thresholdMs = Int64(cfg.thresholds.hibernationAfterSeconds) * 1000
        let nowMs: Int64 = 1_000_000_000
        let lastEventMs = nowMs - thresholdMs // exactly at threshold → shouldEnter true
        let p = pet(lastTickAt: lastEventMs)
        let r = TickCheckpoint.run(pet: p, nowMs: nowMs, lastEventMs: lastEventMs, config: cfg)
        XCTAssertEqual(r.emit, .hibernateStart)
        XCTAssertEqual(r.pet.hibernationSince, nowMs)
        XCTAssertEqual(r.pet.fullness, 50, "no decay on hibernate-enter")
        XCTAssertEqual(r.pet.lastTickAt, nowMs)
    }

    func testWakeReanchorEmitsEnd() {
        let p = pet(lastTickAt: 1_000, hibernating: 5_000)
        let r = TickCheckpoint.run(pet: p, nowMs: 20_000, lastEventMs: 9_000, config: cfg)
        XCTAssertEqual(r.emit, .hibernateEnd)
        XCTAssertNil(r.pet.hibernationSince)
        XCTAssertEqual(r.pet.lastTickAt, 20_000)
        XCTAssertEqual(r.pet.fullness, 50, "wake does not replay sleep span")
    }

    func testStillHibernatingNoNewerEventStaysAsleep() {
        let p = pet(lastTickAt: 1_000, hibernating: 5_000)
        let r = TickCheckpoint.run(pet: p, nowMs: 20_000, lastEventMs: 4_000, config: cfg)
        XCTAssertNil(r.emit)
        XCTAssertEqual(r.pet.hibernationSince, 5_000)
        XCTAssertEqual(r.pet.fullness, 50, "asleep → frozen")
        XCTAssertEqual(r.pet.lastTickAt, 20_000)
    }

    func testStillHibernatingRegensStaminaAtDoubleRate() {
        var p = pet(lastTickAt: 0, hibernating: 5_000)
        p.stamina = 10
        let r = TickCheckpoint.run(pet: p, nowMs: 3_600_000, lastEventMs: 4_000, config: cfg)
        XCTAssertNil(r.emit)
        // 1h asleep → 0.0035 * 2 * 3600 = 25.2, hunger/affection still frozen
        XCTAssertEqual(r.pet.stamina, 10 + 25.2, accuracy: 1e-6)
        XCTAssertEqual(r.pet.fullness, 50, "asleep → hunger frozen")
    }
}
