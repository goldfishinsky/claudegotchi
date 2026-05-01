import XCTest
@testable import PetCore

final class LevelTests: XCTestCase {
    func testLevelTable() {
        XCTAssertEqual(Level.compute(xp: 0), 0)
        XCTAssertEqual(Level.compute(xp: 99), 0)
        XCTAssertEqual(Level.compute(xp: 100), 1)
        XCTAssertEqual(Level.compute(xp: 399), 1)
        XCTAssertEqual(Level.compute(xp: 400), 2)
        XCTAssertEqual(Level.compute(xp: 2_499), 4)
        XCTAssertEqual(Level.compute(xp: 2_500), 5)
        XCTAssertEqual(Level.compute(xp: 9_999), 9)
        XCTAssertEqual(Level.compute(xp: 10_000), 10)
    }

    func testXpForLevelInverts() {
        XCTAssertEqual(Level.xpForLevel(1), 100)
        XCTAssertEqual(Level.xpForLevel(5), 2_500)
        XCTAssertEqual(Level.xpForLevel(10), 10_000)
    }
}
