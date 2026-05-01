import XCTest
import GRDB
@testable import PetCore

final class DailyRollupTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "rollup-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testFreshDateInserts() throws {
        try db.write { conn in
            try DailyRollup.upsert(
                eventDate: "2026-04-30", type: .sessionStart,
                tokensIn: 0, tokensOut: 0, tool: nil, in: conn
            )
        }
        let row = try db.read { try DailyRollup.fetch(date: "2026-04-30", from: $0) }
        XCTAssertEqual(row?.sessions, 1)
        XCTAssertEqual(row?.messages, 0)
    }

    func testPostToolUseAccumulatesTokensAndCount() throws {
        try db.write { conn in
            try DailyRollup.upsert(
                eventDate: "2026-04-30", type: .postToolUse,
                tokensIn: 100, tokensOut: 200, tool: "Bash", in: conn
            )
            try DailyRollup.upsert(
                eventDate: "2026-04-30", type: .postToolUse,
                tokensIn: 50, tokensOut: 75, tool: "Read", in: conn
            )
        }
        let row = try db.read { try DailyRollup.fetch(date: "2026-04-30", from: $0) }!
        XCTAssertEqual(row.toolsUsed, 2)
        XCTAssertEqual(row.tokensIn, 150)
        XCTAssertEqual(row.tokensOut, 275)
        XCTAssertEqual(row.messages, 2)
    }

    func testMixedTypesIncrementCorrectColumns() throws {
        try db.write { conn in
            try DailyRollup.upsert(eventDate: "2026-04-30", type: .sessionStart, tokensIn: 0, tokensOut: 0, tool: nil, in: conn)
            try DailyRollup.upsert(eventDate: "2026-04-30", type: .stop, tokensIn: 0, tokensOut: 0, tool: nil, in: conn)
        }
        let row = try db.read { try DailyRollup.fetch(date: "2026-04-30", from: $0) }!
        XCTAssertEqual(row.sessions, 1)
        XCTAssertEqual(row.messages, 0)
    }

    func testDifferentDatesAreSeparateRows() throws {
        try db.write { conn in
            try DailyRollup.upsert(eventDate: "2026-04-29", type: .sessionStart, tokensIn: 0, tokensOut: 0, tool: nil, in: conn)
            try DailyRollup.upsert(eventDate: "2026-04-30", type: .sessionStart, tokensIn: 0, tokensOut: 0, tool: nil, in: conn)
        }
        let yesterday = try db.read { try DailyRollup.fetch(date: "2026-04-29", from: $0) }!
        let today = try db.read { try DailyRollup.fetch(date: "2026-04-30", from: $0) }!
        XCTAssertEqual(yesterday.sessions, 1)
        XCTAssertEqual(today.sessions, 1)
    }
}
