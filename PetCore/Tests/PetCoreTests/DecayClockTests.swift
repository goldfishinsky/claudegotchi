import XCTest
@testable import PetCore

final class DecayClockTests: XCTestCase {
    func testFixedClockAdvances() {
        let clock = FixedClock(start: 0)
        XCTAssertEqual(clock.nowSeconds(), 0)
        clock.advance(seconds: 60)
        XCTAssertEqual(clock.nowSeconds(), 60)
        clock.advance(seconds: 0.5)
        XCTAssertEqual(clock.nowSeconds(), 60.5, accuracy: 1e-9)
    }

    func testMachClockReturnsRoughlyNow() {
        let clock = MachClock()
        let a = clock.nowSeconds()
        Thread.sleep(forTimeInterval: 0.05)
        let b = clock.nowSeconds()
        XCTAssertGreaterThan(b - a, 0.04)
        XCTAssertLessThan(b - a, 1.0)
    }
}
