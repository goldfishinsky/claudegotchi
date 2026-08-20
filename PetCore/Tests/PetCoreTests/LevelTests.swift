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

    func testGrowthJourneyHasLongHorizonAndLocalProgress() {
        XCTAssertEqual(GrowthJourney.current(xp: 0).nameZh, "初生")
        XCTAssertEqual(GrowthJourney.current(xp: 280_000).nameZh, "觉醒")
        XCTAssertEqual(GrowthJourney.next(xp: 280_000)?.nameZh, "星辉")
        XCTAssertEqual(GrowthJourney.milestones.last?.minXp, 100_000_000)
        XCTAssertEqual(GrowthJourney.progress(xp: 625_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(GrowthJourney.progress(xp: 100_000_000), 1)
    }
}
