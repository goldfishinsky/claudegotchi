import XCTest
@testable import PetCore

final class DeathWindowTests: XCTestCase {
    func testParseEmpty() {
        XCTAssertEqual(DeathWindow.parse("[]"), [])
    }

    func testParseValid() {
        XCTAssertEqual(DeathWindow.parse("[true, false, true]"), [true, false, true])
    }

    func testParseCorruptionReturnsEmpty() {
        XCTAssertEqual(DeathWindow.parse("not-json"), [])
        XCTAssertEqual(DeathWindow.parse("[1, 2, 3]"), [])
    }

    func testParseRejectsIntegerBooleans() {
        XCTAssertEqual(DeathWindow.parse("[1, 0]"), [])
        XCTAssertEqual(DeathWindow.parse("[1]"), [])
    }

    func testSerialize() {
        XCTAssertEqual(DeathWindow.serialize([true, false]), "[true,false]")
    }

    func testAppendTruncatesTo5() {
        var pet = Pet.fresh(species: "frog", at: 0)
        for _ in 0..<10 {
            pet = DeathWindow.appendDay(pet: pet, lowToday: true)
        }
        XCTAssertEqual(DeathWindow.parse(pet.deathWindowState).count, 5)
    }

    func testShouldDieWhenAllFiveTrue() {
        var pet = Pet.fresh(species: "frog", at: 0)
        for _ in 0..<5 {
            pet = DeathWindow.appendDay(pet: pet, lowToday: true)
        }
        XCTAssertTrue(DeathWindow.shouldDie(pet: pet))
    }

    func testShouldNotDieWithOneFalse() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet = DeathWindow.appendDay(pet: pet, lowToday: true)
        pet = DeathWindow.appendDay(pet: pet, lowToday: true)
        pet = DeathWindow.appendDay(pet: pet, lowToday: false)
        pet = DeathWindow.appendDay(pet: pet, lowToday: true)
        pet = DeathWindow.appendDay(pet: pet, lowToday: true)
        XCTAssertFalse(DeathWindow.shouldDie(pet: pet))
    }

    func testShouldNotDieWithFewerThan5() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet = DeathWindow.appendDay(pet: pet, lowToday: true)
        pet = DeathWindow.appendDay(pet: pet, lowToday: true)
        XCTAssertFalse(DeathWindow.shouldDie(pet: pet))
    }

    func testCountLowStats() {
        var pet = Pet.fresh(species: "frog", at: 0)
        pet.fullness = 19; pet.stamina = 19; pet.intimacy = 21
        XCTAssertTrue(DeathWindow.isLowDay(pet: pet, threshold: 20, requiredCount: 2))
        pet.fullness = 21; pet.stamina = 19; pet.intimacy = 21
        XCTAssertFalse(DeathWindow.isLowDay(pet: pet, threshold: 20, requiredCount: 2))
    }
}
