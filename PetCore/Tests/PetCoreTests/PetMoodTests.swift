import XCTest
@testable import PetCore

final class PetMoodTests: XCTestCase {
    private func pet(fullness: Double = 100, stamina: Double = 100, intimacy: Double = 100,
                     xp: Int64 = 0, hibernating: Bool = false) -> Pet {
        var p = Pet.fresh(species: "frog", at: 0)
        p.fullness = fullness; p.stamina = stamina; p.intimacy = intimacy; p.xp = xp
        p.hibernationSince = hibernating ? 1 : nil
        return p
    }

    func testHibernatingIsSleeping() {
        XCTAssertEqual(PetMood.derive(pet: pet(hibernating: true), pressure: .calm).animation, .sleeping)
    }

    func testTwoOfThreeLowIsSick() {
        XCTAssertEqual(PetMood.derive(pet: pet(fullness: 10, stamina: 10), pressure: .calm).animation, .sick)
    }

    func testOneLowIsIdle() {
        XCTAssertEqual(PetMood.derive(pet: pet(fullness: 10), pressure: .calm).animation, .idle)
    }

    func testSleepingBeatsSick() {
        let v = PetMood.derive(pet: pet(fullness: 10, stamina: 10, hibernating: true), pressure: .calm)
        XCTAssertEqual(v.animation, .sleeping)
    }

    func testStageFromXp() {
        XCTAssertEqual(PetMood.derive(pet: pet(xp: 0), pressure: .calm).stage,
                       PixelSpeciesCatalog.stage(id: "frog", xp: 0))
    }

    func testOverlayFromPressure() {
        XCTAssertEqual(PetMood.derive(pet: pet(), pressure: .calm).overlay, PetOverlay.none)
        XCTAssertEqual(PetMood.derive(pet: pet(), pressure: .busy).overlay, .focus)
        XCTAssertEqual(PetMood.derive(pet: pet(), pressure: .stressed).overlay, .sweat)
    }
}
