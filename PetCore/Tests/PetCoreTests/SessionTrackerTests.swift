import XCTest
import GRDB
@testable import PetCore

final class SessionTrackerTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "session-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
        let pet = try Pet.insert(Pet.fresh(species: "frog", at: 0), into: db)
        petId = pet.id!
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    var petId: Int64!

    private func insertEvent(id: String, type: String, ts: Int64,
                             sessionId: String?, cwd: String?, tool: String? = nil,
                             backgroundTasks: Int? = nil) throws {
        var payload: String?
        if tool != nil || backgroundTasks != nil {
            var obj: [String: Any] = [:]
            if let tool { obj["tool"] = tool }
            if let backgroundTasks { obj["background_tasks"] = backgroundTasks }
            payload = String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)
        }
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO event (helper_event_id, ts, type, pet_id, payload, session_id, cwd)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, ts, type, petId!, payload, sessionId, cwd])
        }
    }

    private let window: Int64 = 15 * 60 * 1000

    func testStartedSessionWithRecentActivityIsActive() throws {
        try insertEvent(id: "e1", type: "session_start", ts: 1000, sessionId: "s1", cwd: "/tmp/repo-a")
        try insertEvent(id: "e2", type: "pre_tool_use", ts: 2000, sessionId: "s1", cwd: "/tmp/repo-a", tool: "Bash")
        let now: Int64 = 3000
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: now, windowMs: window,
            repoPaths: [(slug: "o/repo-a", path: "/tmp/repo-a")]
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionId, "s1")
        XCTAssertEqual(sessions[0].repo, "repo-a")
        XCTAssertEqual(sessions[0].startedAtMs, 1000)
        XCTAssertEqual(sessions[0].lastActivityMs, 2000)
        XCTAssertEqual(sessions[0].lastTool, "Bash")
    }

    func testStopClosesSession() throws {
        try insertEvent(id: "e1", type: "session_start", ts: 1000, sessionId: "s1", cwd: "/tmp/r")
        try insertEvent(id: "e2", type: "stop", ts: 2000, sessionId: "s1", cwd: "/tmp/r")
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: 2500, windowMs: window, repoPaths: []
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    func testStopWithPendingBackgroundTasksStaysActive() throws {
        try insertEvent(id: "e1", type: "session_start", ts: 1000, sessionId: "s1", cwd: "/tmp/r")
        try insertEvent(id: "e2", type: "post_tool_use", ts: 2000, sessionId: "s1", cwd: "/tmp/r", tool: "Bash")
        try insertEvent(id: "e3", type: "stop", ts: 3000, sessionId: "s1", cwd: "/tmp/r", backgroundTasks: 1)
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: 3500, windowMs: window, repoPaths: []
        )
        XCTAssertEqual(sessions.count, 1, "a stop with pending background work does not close the session")
        XCTAssertEqual(sessions[0].backgroundTasks, 1)
        XCTAssertEqual(sessions[0].lastActivityMs, 3000)
    }

    func testStopWithZeroBackgroundTasksClosesSession() throws {
        try insertEvent(id: "e1", type: "session_start", ts: 1000, sessionId: "s1", cwd: "/tmp/r")
        try insertEvent(id: "e2", type: "stop", ts: 2000, sessionId: "s1", cwd: "/tmp/r", backgroundTasks: 0)
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: 2500, windowMs: window, repoPaths: []
        )
        XCTAssertTrue(sessions.isEmpty, "a drained stop closes the session")
    }

    func testResumedAfterStopStaysActive() throws {
        try insertEvent(id: "e1", type: "session_start", ts: 1000, sessionId: "s1", cwd: "/tmp/r")
        try insertEvent(id: "e2", type: "post_tool_use", ts: 2000, sessionId: "s1", cwd: "/tmp/r", tool: "Bash")
        try insertEvent(id: "e3", type: "stop", ts: 3000, sessionId: "s1", cwd: "/tmp/r")
        try insertEvent(id: "e4", type: "pre_tool_use", ts: 4000, sessionId: "s1", cwd: "/tmp/r", tool: "Read")
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: 4500, windowMs: window, repoPaths: []
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].lastActivityMs, 4000)
        XCTAssertEqual(sessions[0].lastTool, "Read")
    }

    func testStaleActivityOutsideWindowExcluded() throws {
        try insertEvent(id: "e1", type: "session_start", ts: 0, sessionId: "s1", cwd: "/tmp/r")
        try insertEvent(id: "e2", type: "pre_tool_use", ts: 100, sessionId: "s1", cwd: "/tmp/r", tool: "Read")
        let now = window + 1000
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: now, windowMs: window, repoPaths: []
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    func testRepoLabelLongestPrefixWins() throws {
        try insertEvent(id: "e1", type: "session_start", ts: 1000, sessionId: "s1",
                        cwd: "/tmp/repo-a/packages/web")
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: 1500, windowMs: window,
            repoPaths: [(slug: "o/repo-a", path: "/tmp/repo-a"),
                        (slug: "o/web", path: "/tmp/repo-a/packages/web")]
        )
        XCTAssertEqual(sessions[0].repo, "web")
    }

    func testMissingCwdYieldsUnknownRepo() throws {
        try insertEvent(id: "e1", type: "session_start", ts: 1000, sessionId: "s1", cwd: nil)
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: 1500, windowMs: window, repoPaths: []
        )
        XCTAssertEqual(sessions[0].repo, "(unknown)")
        XCTAssertNil(sessions[0].cwd)
    }

    func testMissingSessionIdRowsIgnored() throws {
        try insertEvent(id: "e1", type: "pre_tool_use", ts: 1000, sessionId: nil, cwd: "/tmp/r", tool: "Bash")
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: 1500, windowMs: window, repoPaths: []
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    func testPrEventsIgnored() throws {
        try insertEvent(id: "e1", type: "pr_approved", ts: 1000, sessionId: nil, cwd: nil)
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: 1500, windowMs: window, repoPaths: []
        )
        XCTAssertTrue(sessions.isEmpty)
    }
}
