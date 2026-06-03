import XCTest
import GRDB
@testable import PetCore

final class HatchServiceTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "hatch-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testHatchesWhenEmpty() throws {
        let pet = try HatchService.ensureAlive(db, nowMs: 7777)
        XCTAssertTrue(PixelSpeciesCatalog.ids.contains(pet.species))
        XCTAssertEqual(pet.lastTickAt, 7777)
        XCTAssertEqual(pet.lastEventAt, 7777)
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pet") }
        XCTAssertEqual(count, 1)
    }

    func testNoOpWhenAlive() throws {
        let existing = try Pet.insert(.fresh(species: "frog", at: 100), into: db)
        let returned = try HatchService.ensureAlive(db, nowMs: 9999)
        XCTAssertEqual(returned.id, existing.id)
        XCTAssertEqual(returned.lastTickAt, 100, "existing pet untouched")
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pet") }
        XCTAssertEqual(count, 1)
    }
}
