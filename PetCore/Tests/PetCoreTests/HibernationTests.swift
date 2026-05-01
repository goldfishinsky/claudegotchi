import XCTest
@testable import PetCore

final class HibernationTests: XCTestCase {
    let cfg = ConfigYAML.defaults

    func testShouldEnterAfterThreshold() {
        XCTAssertTrue(Hibernation.shouldEnter(nowSeconds: 259201, lastEventSeconds: 0, config: cfg))
    }

    func testShouldNotEnterBeforeThreshold() {
        XCTAssertFalse(Hibernation.shouldEnter(nowSeconds: 259199, lastEventSeconds: 0, config: cfg))
    }

    func testShouldEnterAtBoundary() {
        XCTAssertTrue(Hibernation.shouldEnter(nowSeconds: 259200, lastEventSeconds: 0, config: cfg))
    }

    func testShouldWakeWhenHibernating() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.hibernationSince = 100
        XCTAssertTrue(Hibernation.shouldWake(pet: pet))
    }

    func testShouldNotWakeWhenAwake() {
        let pet = Pet.fresh(species: "frog", at: 0)
        XCTAssertFalse(Hibernation.shouldWake(pet: pet))
    }
}
