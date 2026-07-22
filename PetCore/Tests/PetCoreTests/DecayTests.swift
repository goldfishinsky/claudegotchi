import XCTest
@testable import PetCore

final class DecayTests: XCTestCase {
    let cfg = ConfigYAML.defaults

    func testFullnessDecaysAtRate() {
        let pet = Pet.fresh(species: "frog", at: 0)
        // 1 hour → 0.0006 * 3600 = 2.16 drop
        let next = Decay.apply(pet: pet, elapsedSeconds: 3600, config: cfg)
        XCTAssertEqual(next.fullness, 100 - 2.16, accuracy: 1e-6)
    }

    func testIntimacyDecaysAtRate() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.intimacy = 80
        let next = Decay.apply(pet: pet, elapsedSeconds: 3600, config: cfg)
        XCTAssertEqual(next.intimacy, 80 - 1.08, accuracy: 1e-6)
    }

    func testStaminaRegenerates() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 50
        // 1 hour → 0.0035 * 3600 = 12.6 gain
        let next = Decay.apply(pet: pet, elapsedSeconds: 3600, config: cfg)
        XCTAssertEqual(next.stamina, 50 + 12.6, accuracy: 1e-6)
    }

    func testHibernatingDoublesStaminaRegen() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 20
        let next = Decay.apply(pet: pet, elapsedSeconds: 3600, config: cfg, hibernating: true)
        XCTAssertEqual(next.stamina, 20 + 25.2, accuracy: 1e-6)
    }

    func testHibernatingFreezesHungerAndAffection() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 60; pet.intimacy = 60
        let next = Decay.apply(pet: pet, elapsedSeconds: 86400, config: cfg, hibernating: true)
        XCTAssertEqual(next.fullness, 60, accuracy: 1e-9)
        XCTAssertEqual(next.intimacy, 60, accuracy: 1e-9)
    }

    func testStatsClampToZero() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 1
        let next = Decay.apply(pet: pet, elapsedSeconds: 1_000_000, config: cfg)
        XCTAssertEqual(next.fullness, 0)
    }

    func testStaminaClampsTo100() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.stamina = 99.9
        let next = Decay.apply(pet: pet, elapsedSeconds: 1_000_000, config: cfg)
        XCTAssertEqual(next.stamina, 100)
    }

    func testXPNeverChangesOnDecay() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.xp = 12345
        let next = Decay.apply(pet: pet, elapsedSeconds: 86400, config: cfg)
        XCTAssertEqual(next.xp, 12345)
    }

    func testFiveDayTotalDrop() {
        let pet = Pet.fresh(species: "frog", at: 0)
        let next = Decay.apply(pet: pet, elapsedSeconds: 86400 * 5, config: cfg)
        XCTAssertEqual(next.fullness, 0)
        XCTAssertEqual(next.intimacy, 0)
    }
}
