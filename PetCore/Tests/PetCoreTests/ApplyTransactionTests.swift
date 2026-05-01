import XCTest
import GRDB
@testable import PetCore

final class ApplyTransactionTests: XCTestCase {
    var dbPath: String!
    var db: DatabaseQueue!
    var pet: Pet!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "atx-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
        pet = try Pet.insert(.fresh(species: "frog", at: 0), into: db)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func eventJSON(eventId: String, type: String = "post_tool_use",
                           tokensIn: Int = 100, tokensOut: Int = 100, ts: Int64 = 1714500000123) -> String {
        #"""
        {"schema_version":1,"event_id":"\#(eventId)","ts":\#(ts),"type":"\#(type)","session_id":"s","tool":"Bash","tokens_in":\#(tokensIn),"tokens_out":\#(tokensOut)}
        """#
    }

    func testFreshLineCommitsAllFourSteps() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A"))

        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 1)
        let date = try db.read { try String.fetchOne($0, sql: "SELECT date FROM daily_rollup") }
        XCTAssertNotNil(date)
        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.xp, 1)
        XCTAssertGreaterThan(p.lastAppliedEventId, 0)
    }

    func testDuplicateHelperEventIdNoOp() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let line = eventJSON(eventId: "01H0000000000000000000000A")
        try atx.process(jsonLine: line)
        try atx.process(jsonLine: line)
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 1, "Duplicate helper_event_id must be silently ignored")
        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.xp, 1, "Stat must not be applied twice")
    }

    func testPausedSkipsEventApplierButWritesEventAndRollup() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: true)
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A"))
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 1)
        let date = try db.read { try String.fetchOne($0, sql: "SELECT date FROM daily_rollup") }
        XCTAssertNotNil(date)
        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.xp, 0, "Paused → applier did NOT run; xp unchanged")
        XCTAssertGreaterThan(p.lastAppliedEventId, 0, "Watermark advances even when paused")
    }

    func testWatermarkAdvancesMonotonically() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A", ts: 1000))
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000B", ts: 2000))
        let p = try Pet.fetchAlive(from: db)!
        let ids = try db.read { try Int64.fetchAll($0, sql: "SELECT id FROM event ORDER BY id") }
        XCTAssertEqual(p.lastAppliedEventId, ids.last!)
    }

    func testMalformedJSONRejected() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        XCTAssertThrowsError(try atx.process(jsonLine: "not-json"))
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 0)
    }
}
