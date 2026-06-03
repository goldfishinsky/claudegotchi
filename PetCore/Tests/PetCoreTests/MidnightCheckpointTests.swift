import XCTest
import GRDB
@testable import PetCore

final class MidnightCheckpointTests: XCTestCase {
    var dbPath: String!
    var db: DatabaseQueue!
    let cfg = ConfigYAML.defaults
    let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "midnight-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private let msPerDay: Int64 = 86_400_000

    func testLocalDayKeyAdvancesOncePerDayInUTC() {
        XCTAssertEqual(MidnightCheckpoint.localDayKey(unixMs: 0, timeZone: utc), 0)
        XCTAssertEqual(MidnightCheckpoint.localDayKey(unixMs: msPerDay - 1, timeZone: utc), 0)
        XCTAssertEqual(MidnightCheckpoint.localDayKey(unixMs: msPerDay, timeZone: utc), 1)
        XCTAssertEqual(MidnightCheckpoint.localDayKey(unixMs: 5 * msPerDay + 123, timeZone: utc), 5)
    }

    func testShouldRunOnlyAfterDayRollover() {
        // Never run before → run.
        XCTAssertTrue(MidnightCheckpoint.shouldRun(lastCheckpointDay: nil, nowMs: 0, timeZone: utc))
        // Same day → skip.
        XCTAssertFalse(MidnightCheckpoint.shouldRun(lastCheckpointDay: 0, nowMs: msPerDay - 1, timeZone: utc))
        // Next day → run.
        XCTAssertTrue(MidnightCheckpoint.shouldRun(lastCheckpointDay: 0, nowMs: msPerDay, timeZone: utc))
        // Many days later (app slept through several) → run.
        XCTAssertTrue(MidnightCheckpoint.shouldRun(lastCheckpointDay: 0, nowMs: 9 * msPerDay, timeZone: utc))
    }

    func testCheckpointAppendsLowDayForLowPet() throws {
        var p = Pet.fresh(species: "frog", at: 0)
        p.fullness = 5; p.stamina = 5; p.intimacy = 50
        _ = try Pet.insert(p, into: db)

        let result = try MidnightCheckpoint.runCheckpoint(db: db, config: cfg, nowMs: 1000)

        XCTAssertTrue(result.ran)
        XCTAssertFalse(result.died)
        let alive = try Pet.fetchAlive(from: db)!
        let window = DeathWindow.parse(alive.deathWindowState)
        XCTAssertEqual(window, [true], "A low day appends `true` to the death window")
    }

    func testCheckpointAppendsHealthyDayForHealthyPet() throws {
        var p = Pet.fresh(species: "frog", at: 0)
        p.fullness = 100; p.stamina = 100; p.intimacy = 100
        _ = try Pet.insert(p, into: db)

        let result = try MidnightCheckpoint.runCheckpoint(db: db, config: cfg, nowMs: 1000)

        XCTAssertTrue(result.ran)
        XCTAssertFalse(result.died)
        let alive = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(DeathWindow.parse(alive.deathWindowState), [false])
    }

    func testCheckpointMarksPetDeadAfterConsecutiveLowDays() throws {
        var p = Pet.fresh(species: "frog", at: 0)
        p.fullness = 1; p.stamina = 1; p.intimacy = 50
        _ = try Pet.insert(p, into: db)

        var died = false
        for day in 0..<cfg.thresholds.deathConsecutiveDays {
            let result = try MidnightCheckpoint.runCheckpoint(
                db: db, config: cfg, nowMs: Int64(day + 1) * 1000
            )
            died = result.died
        }

        XCTAssertTrue(died, "After \(cfg.thresholds.deathConsecutiveDays) low days, the pet dies")
        XCTAssertNil(try Pet.fetchAlive(from: db), "Dead pet is no longer the alive pet")
        let dead = try Pet.fetchAllDead(from: db)
        XCTAssertEqual(dead.count, 1)
        XCTAssertEqual(dead.first?.deathAt, Int64(cfg.thresholds.deathConsecutiveDays) * 1000)
    }

    func testCheckpointIsNoOpWhenNoAlivePet() throws {
        let result = try MidnightCheckpoint.runCheckpoint(db: db, config: cfg, nowMs: 1000)
        XCTAssertFalse(result.ran)
        XCTAssertFalse(result.died)
    }

    func testHealthyDayResetsTowardSafetyAndPetSurvives() throws {
        var p = Pet.fresh(species: "frog", at: 0)
        p.fullness = 1; p.stamina = 1; p.intimacy = 50
        _ = try Pet.insert(p, into: db)

        // Four low days (one short of death), then a recovery day.
        for day in 0..<(cfg.thresholds.deathConsecutiveDays - 1) {
            _ = try MidnightCheckpoint.runCheckpoint(db: db, config: cfg, nowMs: Int64(day + 1) * 1000)
        }
        try db.write { conn in
            try conn.execute(sql: "UPDATE pet SET fullness = 100, stamina = 100, intimacy = 100 WHERE death_at IS NULL")
        }
        let recovery = try MidnightCheckpoint.runCheckpoint(db: db, config: cfg, nowMs: 9000)

        XCTAssertFalse(recovery.died, "A healthy day breaks the consecutive-low streak")
        XCTAssertNotNil(try Pet.fetchAlive(from: db))
    }
}
