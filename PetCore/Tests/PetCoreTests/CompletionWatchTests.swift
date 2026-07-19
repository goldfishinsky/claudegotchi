import XCTest
import GRDB
@testable import PetCore

final class CompletionWatchTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!
    var petId: Int64!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "completion-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
        petId = try Pet.insert(Pet.fresh(species: "frog", at: 0), into: db).id!
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func insert(id: String, type: String, ts: Int64, sessionId: String?,
                        cwd: String?, prompt: String? = nil) throws {
        var obj: [String: Any] = ["type": type, "ts": ts]
        if let prompt { obj["prompt"] = prompt }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO event (helper_event_id, ts, type, pet_id, payload, session_id, cwd)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, ts, type, petId!, String(data: data, encoding: .utf8), sessionId, cwd])
        }
    }

    // MARK: query

    func testStopAsLatestEventIsCompletion() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/repo-a")
        try insert(id: "e2", type: "stop", ts: now - 5_000, sessionId: "s1", cwd: "/tmp/repo-a")
        let stops = try CompletionWatch.recentCompletions(db: db, nowMs: now)
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops[0].sessionId, "s1")
        XCTAssertEqual(stops[0].repoName, "repo-a")
        XCTAssertEqual(stops[0].tsMs, now - 5_000)
    }

    func testResumedAfterStopIsNotCompletion() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "stop", ts: now - 20_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e3", type: "pre_tool_use", ts: now - 5_000, sessionId: "s1", cwd: "/tmp/r")
        XCTAssertTrue(try CompletionWatch.recentCompletions(db: db, nowMs: now).isEmpty)
    }

    func testStopOutsideWindowExcluded() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: 0, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "stop", ts: 100, sessionId: "s1", cwd: "/tmp/r")
        XCTAssertTrue(try CompletionWatch.recentCompletions(db: db, nowMs: now, windowMs: 60_000).isEmpty)
    }

    func testFilterHidesNoiseCompletion() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/hookprobe/x")
        try insert(id: "e2", type: "stop", ts: now - 5_000, sessionId: "s1", cwd: "/tmp/hookprobe/x")
        try insert(id: "p1", type: "session_start", ts: now - 30_000, sessionId: "s2", cwd: "/tmp/r")
        try insert(id: "p2", type: "user_prompt_submit", ts: now - 29_000, sessionId: "s2", cwd: "/tmp/r",
                   prompt: "<task-notification>agent done</task-notification>")
        try insert(id: "p3", type: "stop", ts: now - 4_000, sessionId: "s2", cwd: "/tmp/r")
        let filter = SessionFilter(directoryPatterns: ["/hookprobe"],
                                   promptPrefixPatterns: ["<task-notification>"])
        XCTAssertTrue(try CompletionWatch.recentCompletions(db: db, nowMs: now, filter: filter).isEmpty)
    }

    func testCompletionCarriesTitle() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "user_prompt_submit", ts: now - 29_000, sessionId: "s1", cwd: "/tmp/r",
                   prompt: "构建设置面板")
        try insert(id: "e3", type: "stop", ts: now - 4_000, sessionId: "s1", cwd: "/tmp/r")
        let stops = try CompletionWatch.recentCompletions(db: db, nowMs: now)
        XCTAssertEqual(stops[0].title, "构建设置面板")
    }

    // MARK: dedupe state machine

    func testPrimingSuppressesPreexistingStops() {
        var d = CompletionDetector()
        let pre = [SessionStop(sessionId: "s1", cwd: "/r", title: nil, tsMs: 100)]
        XCTAssertTrue(d.newlyCompleted(pre).isEmpty, "first observation only primes the baseline")
    }

    func testNewSessionCompletionEmitsOnce() {
        var d = CompletionDetector()
        _ = d.newlyCompleted([])
        let first = d.newlyCompleted([SessionStop(sessionId: "s1", cwd: "/r", title: nil, tsMs: 200)])
        XCTAssertEqual(first.map(\.sessionId), ["s1"])
        let again = d.newlyCompleted([SessionStop(sessionId: "s1", cwd: "/r", title: nil, tsMs: 200)])
        XCTAssertTrue(again.isEmpty, "same stop must not re-reveal")
    }

    func testNewTurnAdvancingTimestampReemits() {
        var d = CompletionDetector(primed: true)
        _ = d.newlyCompleted([SessionStop(sessionId: "s1", cwd: "/r", title: nil, tsMs: 200)])
        let next = d.newlyCompleted([SessionStop(sessionId: "s1", cwd: "/r", title: nil, tsMs: 500)])
        XCTAssertEqual(next.map(\.tsMs), [500], "a later stop is a new completion")
    }

    func testMultipleSessionsIndependent() {
        var d = CompletionDetector(primed: true)
        let out = d.newlyCompleted([
            SessionStop(sessionId: "s1", cwd: "/a", title: nil, tsMs: 100),
            SessionStop(sessionId: "s2", cwd: "/b", title: nil, tsMs: 100),
        ])
        XCTAssertEqual(Set(out.map(\.sessionId)), ["s1", "s2"])
        let out2 = d.newlyCompleted([
            SessionStop(sessionId: "s1", cwd: "/a", title: nil, tsMs: 100),
            SessionStop(sessionId: "s2", cwd: "/b", title: nil, tsMs: 300),
        ])
        XCTAssertEqual(out2.map(\.sessionId), ["s2"], "only the advanced session re-emits")
    }
}
