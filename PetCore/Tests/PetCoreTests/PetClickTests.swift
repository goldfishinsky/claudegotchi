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
