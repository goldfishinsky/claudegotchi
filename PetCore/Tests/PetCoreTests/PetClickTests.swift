import XCTest
@testable import PetCore

final class PetClickTests: XCTestCase {
    func testAllowedWhenNeverClicked() {
        XCTAssertTrue(PetClick.allowed(lastClickMs: nil, nowMs: 1000, cooldownSeconds: 60))
    }

    func testBlockedWithinCooldown() {
        XCTAssertFalse(PetClick.allowed(lastClickMs: 0, nowMs: 30_000, cooldownSeconds: 60))
    }

    func testAllowedAtBoundary() {
        XCTAssertTrue(PetClick.allowed(lastClickMs: 0, nowMs: 60_000, cooldownSeconds: 60))
    }

    func testAllowedAfterCooldown() {
        XCTAssertTrue(PetClick.allowed(lastClickMs: 0, nowMs: 61_000, cooldownSeconds: 60))
    }

    func testClockSkewBlocks() {
        XCTAssertFalse(PetClick.allowed(lastClickMs: 100_000, nowMs: 50_000, cooldownSeconds: 60))
    }
}

final class PetPettingTests: XCTestCase {
    func testFirstPettingAlwaysAccrues() {
        XCTAssertTrue(PetPetting.shouldAccrue(lastAccrualMs: nil, nowMs: 1_000))
    }

    func testPettingCappedWithinSameWindow() {
        let last: Int64 = 1_000
        XCTAssertFalse(PetPetting.shouldAccrue(lastAccrualMs: last, nowMs: last + 5 * 60_000),
                       "second accrual inside the same 10-min window is capped")
    }

    func testPettingAccruesInNextWindow() {
        let last: Int64 = 1_000
        XCTAssertTrue(PetPetting.shouldAccrue(lastAccrualMs: last, nowMs: last + PetPetting.windowMs))
    }

    func testEventIdStableWithinWindowChangesAcross() {
        let a = PetPetting.eventId(petId: 7, nowMs: 1_000)
        let b = PetPetting.eventId(petId: 7, nowMs: 5 * 60_000)
        let c = PetPetting.eventId(petId: 7, nowMs: 1_000 + PetPetting.windowMs)
        XCTAssertEqual(a, b, "same window → same id → idempotent on replay")
        XCTAssertNotEqual(a, c, "next window → new id → a fresh accrual")
        XCTAssertEqual(a, "pet:7:0")
    }
}
