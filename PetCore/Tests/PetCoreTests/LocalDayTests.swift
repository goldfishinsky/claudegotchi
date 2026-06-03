import XCTest
import GRDB
@testable import PetCore

final class LocalDayTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testKeyFormatUTC() {
        // 2026-06-03T00:00:00Z = 1780444800000 ms
        XCTAssertEqual(LocalDay.key(unixMs: 1_780_444_800_000, timeZone: utc), "2026-06-03")
    }

    func testDayIndexIsContiguous() {
        let d0 = LocalDay.dayIndex(unixMs: 1_780_444_800_000, timeZone: utc)               // 2026-06-03
        let d1 = LocalDay.dayIndex(unixMs: 1_780_444_800_000 + 86_400_000, timeZone: utc)  // next day
        XCTAssertEqual(d1, d0 + 1)
    }

    func testTodayKeyMatchesRollupKeyForSameDayEvent() throws {
        let dbPath = NSTemporaryDirectory() + "localday-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        _ = try Pet.insert(.fresh(species: "frog", at: 0), into: db)
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let ts: Int64 = 1_780_490_000_000
        let line = #"{"schema_version":1,"event_id":"01H0000000000000000000000A","ts":\#(ts),"type":"session_start","session_id":"s"}"#
        try atx.process(jsonLine: line)
        let rollupKey = try db.read { try String.fetchOne($0, sql: "SELECT date FROM daily_rollup") }!
        XCTAssertEqual(rollupKey, LocalDay.key(unixMs: ts, timeZone: TimeZone.current))
    }
}
