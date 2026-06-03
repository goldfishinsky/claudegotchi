import XCTest
import GRDB
@testable import PetCore

final class PetTests: XCTestCase {
    var dbPath: String!
    var db: DatabaseQueue!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "pet-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testInsertAndFetchAlive() throws {
        let pet = Pet.fresh(species: "frog", at: 1_000_000)
        let inserted = try Pet.insert(pet, into: db)
        XCTAssertNotNil(inserted.id)
        let fetched = try Pet.fetchAlive(from: db)
        XCTAssertEqual(fetched?.id, inserted.id)
        XCTAssertEqual(fetched?.species, "frog")
        XCTAssertEqual(fetched?.fullness, 100)
    }

    func testFetchAliveReturnsNilWhenNoneAlive() throws {
        XCTAssertNil(try Pet.fetchAlive(from: db))
    }

    func testMarkDead() throws {
        let pet = try Pet.insert(.fresh(species: "frog", at: 0), into: db)
        try Pet.markDead(id: pet.id!, at: 5_000_000, in: db)
        XCTAssertNil(try Pet.fetchAlive(from: db))
        let dead = try Pet.fetchAllDead(from: db)
        XCTAssertEqual(dead.count, 1)
        XCTAssertEqual(dead.first?.deathAt, 5_000_000)
    }

    func testInsertingSecondAliveFails() throws {
        _ = try Pet.insert(.fresh(species: "frog", at: 0), into: db)
        XCTAssertThrowsError(try Pet.insert(.fresh(species: "cat", at: 0), into: db))
    }

    func testFreshSetsLastEventAtToTs() {
        let pet = Pet.fresh(species: "frog", at: 12345)
        XCTAssertEqual(pet.lastEventAt, 12345)
    }

    func testLastEventAtRoundTrips() throws {
        // Requires the v3 `last_event_at` column (added by Task 2's migration).
        let dbPath = NSTemporaryDirectory() + "pet-lea-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        var pet = try Pet.insert(.fresh(species: "frog", at: 1000), into: db)
        XCTAssertEqual(pet.lastEventAt, 1000)
        pet.lastEventAt = 9999
        try Pet.update(pet, in: db)
        let fetched = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(fetched.lastEventAt, 9999)
    }
}
