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

    func testPettingEventCreditsIntimacyOnceAndReplaysCleanly() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let before = try Pet.fetchAlive(from: db)!.intimacy
        let e = Event(
            schemaVersion: 1, eventId: PetPetting.eventId(petId: pet.id!, nowMs: 1000),
            ts: 1000, type: .petting,
            sessionId: nil, tool: nil, tokensIn: nil, tokensOut: nil, model: nil)
        try atx.process(event: e)
        let once = try Pet.fetchAlive(from: db)!.intimacy
        try atx.process(event: e)
        let twice = try Pet.fetchAlive(from: db)!.intimacy
        XCTAssertGreaterThan(once, before, "petting accrues intimacy")
        XCTAssertEqual(once, twice, "same-bucket replay must not double-credit")
        let count = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event WHERE type = 'petting'")
        }
        XCTAssertEqual(count, 1)
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

    func testHookLineLandsSessionIdAndCwdInTypedColumns() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let line = #"""
        {"schema_version":1,"event_id":"01H0000000000000000000000A","ts":1714500000123,"type":"session_start","session_id":"sess-xyz","cwd":"/Users/jalen/repo"}
        """#
        try atx.process(jsonLine: line)
        let row = try db.read { conn -> (String?, String?) in
            let sid = try String.fetchOne(conn, sql: "SELECT session_id FROM event LIMIT 1")
            let cwd = try String.fetchOne(conn, sql: "SELECT cwd FROM event LIMIT 1")
            return (sid, cwd)
        }
        XCTAssertEqual(row.0, "sess-xyz")
        XCTAssertEqual(row.1, "/Users/jalen/repo")
    }

    private func prEvent(eventId: String, type: Event.EventType, ts: Int64 = 1714500000123) -> Event {
        Event(schemaVersion: 1, eventId: eventId, ts: ts, type: type,
              sessionId: nil, tool: nil, tokensIn: nil, tokensOut: nil, model: nil, cwd: nil)
    }

    func testProcessEventInsertsWithNullSessionAndCwdAndSkipsRollup() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let input = prEvent(eventId: "pr:o/r#1:approved:1000", type: .prApproved)
        try atx.process(event: input)

        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 1)
        let nullCols = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event WHERE session_id IS NULL AND cwd IS NULL")
        }
        XCTAssertEqual(nullCols, 1, "Synthetic events insert session_id/cwd as NULL")
        let rollupRows = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM daily_rollup") }
        XCTAssertEqual(rollupRows, 0, "PR events skip the rollup path")

        let payload = try db.read {
            try String.fetchOne($0, sql: "SELECT payload FROM event WHERE helper_event_id = ?",
                                arguments: ["pr:o/r#1:approved:1000"])
        }!
        let roundTripped = try Event.parse(payload)
        XCTAssertEqual(roundTripped, input, "Synthetic payload round-trips byte-stable on replay")
        XCTAssertNil(roundTripped.cwd)
        XCTAssertNil(roundTripped.sessionId)

        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.intimacy, 50 + ConfigYAML.defaults.work.prApprovedIntimacy, accuracy: 1e-9)
        XCTAssertGreaterThan(p.lastAppliedEventId, 0)
    }

    func testProcessEventDuplicateNoDoubleCount() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let e = prEvent(eventId: "pr:o/r#1:approved:1000", type: .prApproved)
        try atx.process(event: e)
        try atx.process(event: e)
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 1, "Duplicate synthetic event_id ignored")
        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.intimacy, 50 + ConfigYAML.defaults.work.prApprovedIntimacy, accuracy: 1e-9)
    }

    func testProcessEventPausedDropsNudgeButAdvancesWatermark() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: true)
        try atx.process(event: prEvent(eventId: "pr:o/r#1:merged:2000", type: .prMerged))
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 1)
        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.xp, 0, "Paused → nudge dropped")
        XCTAssertGreaterThan(p.lastAppliedEventId, 0, "Watermark advances while paused")
    }

    func testProcessEventReplayIdempotent() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let merged = prEvent(eventId: "pr:o/r#1:merged:2000", type: .prMerged)
        try atx.process(event: merged)
        try atx.process(event: merged)
        try atx.process(event: merged)
        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.xp, ConfigYAML.defaults.work.prMergedXp, "xp banked exactly once across replays")
    }

    func testProcessJsonLineBumpsModelUsageOnce() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let line = #"{"schema_version":1,"event_id":"01H0000000000000000000000A","ts":1714500000123,"type":"post_tool_use","session_id":"s","tool":"Bash","tokens_in":100,"tokens_out":200,"model":"opus"}"#
        try atx.process(jsonLine: line)
        try atx.process(jsonLine: line) // duplicate: dedup short-circuit → must NOT double-bank
        let all = try ModelUsageStore.all(in: db)
        XCTAssertEqual(all, [ModelUsage(model: "opus", tokensIn: 100, tokensOut: 200, calls: 1)])
    }

    func testProcessJsonLineAdvancesLastEventAt() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A", ts: 5000))
        XCTAssertEqual(try Pet.fetchAlive(from: db)!.lastEventAt, 5000)
        // An older event must NOT move last_event_at backward (MAX semantics).
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000B", ts: 3000))
        XCTAssertEqual(try Pet.fetchAlive(from: db)!.lastEventAt, 5000)
    }

    func testStopWithModelBumpsModelUsageAndRollupTokens() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let line = #"{"schema_version":1,"event_id":"01H0000000000000000000000A","ts":1714500000123,"type":"stop","session_id":"s","tokens_in":199,"tokens_out":38,"model":"claude-haiku-4-5-20251001"}"#
        try atx.process(jsonLine: line)
        try atx.process(jsonLine: line) // dedup: must not double-bank
        let all = try ModelUsageStore.all(in: db)
        XCTAssertEqual(all, [ModelUsage(model: "claude-haiku-4-5-20251001", tokensIn: 199, tokensOut: 38, calls: 1)])
        let rollup = try db.read { try DailyRollup.fetch(date: LocalDay.key(unixMs: 1714500000123, timeZone: .current), from: $0) }!
        XCTAssertEqual(rollup.tokensIn, 199)
        XCTAssertEqual(rollup.tokensOut, 38)
    }

    func testUserPromptSubmitIsNoOpButBumpsLastEventAt() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let xpBefore = try Pet.fetchAlive(from: db)!.xp
        let line = #"{"schema_version":1,"event_id":"01H0000000000000000000000A","ts":7000,"type":"user_prompt_submit","session_id":"s","cwd":"/w","prompt":"修复登录按钮样式"}"#
        try atx.process(jsonLine: line)

        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.xp, xpBefore, "prompt submit does not feed the pet")
        XCTAssertEqual(p.fullness, 100, accuracy: 1e-9)
        XCTAssertEqual(p.stamina, 100, accuracy: 1e-9)
        XCTAssertEqual(p.intimacy, 50, accuracy: 1e-9)
        XCTAssertEqual(p.lastEventAt, 7000, "last_event_at still advances")
        XCTAssertEqual(try ModelUsageStore.all(in: db).count, 0, "no model usage banked")

        let rollup = try db.read {
            try DailyRollup.fetch(date: LocalDay.key(unixMs: 7000, timeZone: .current), from: $0)
        }!
        XCTAssertEqual(rollup.sessions, 0)
        XCTAssertEqual(rollup.messages, 0)
        XCTAssertEqual(rollup.tokensIn, 0)
        XCTAssertEqual(rollup.tokensOut, 0)
        XCTAssertEqual(rollup.toolsUsed, 0)

        let storedPrompt = try db.read {
            try String.fetchOne($0, sql: "SELECT json_extract(payload, '$.prompt') FROM event LIMIT 1")
        }
        XCTAssertEqual(storedPrompt, "修复登录按钮样式", "prompt survives in payload for the title query")
    }

    func testPostToolUseWithoutModelSkipsModelUsage() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A"))
        XCTAssertEqual(try ModelUsageStore.all(in: db).count, 0)
    }

    func testSyntheticEventSkipsModelUsageAndLastEventAt() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        try atx.process(event: prEvent(eventId: "pr:o/r#1:approved:1000", type: .prApproved))
        XCTAssertEqual(try ModelUsageStore.all(in: db).count, 0)
        XCTAssertEqual(try Pet.fetchAlive(from: db)!.lastEventAt, 0, "synthetic events do not advance last_event_at")
    }

    func testProcessJsonLinePostsPetDidChangeOnApply() throws {
        let exp = expectation(forNotification: .claudegotchiPetDidChange, object: nil, handler: nil)
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A"))
        wait(for: [exp], timeout: 1.0)
    }

    func testDuplicateSpoolLineDoesNotPostPetDidChange() throws {
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A")) // first apply
        let exp = expectation(forNotification: .claudegotchiPetDidChange, object: nil, handler: nil)
        exp.isInverted = true
        try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A")) // dedup → no post
        wait(for: [exp], timeout: 0.5)
    }
}
