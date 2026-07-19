import XCTest
import GRDB
@testable import PetCore

final class PermissionWatchTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!
    var petId: Int64!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "perm-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
        petId = try Pet.insert(Pet.fresh(species: "frog", at: 0), into: db).id!
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func insert(id: String, type: String, ts: Int64, sessionId: String?, cwd: String?,
                        message: String? = nil, notificationType: String? = nil) throws {
        var obj: [String: Any] = ["type": type, "ts": ts]
        if let message { obj["message"] = message }
        if let notificationType { obj["notification_type"] = notificationType }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO event (helper_event_id, ts, type, pet_id, payload, session_id, cwd)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, ts, type, petId!, String(data: data, encoding: .utf8), sessionId, cwd])
        }
    }

    func testIsPermissionRequestUnit() {
        XCTAssertTrue(PermissionWatch.isPermissionRequest(
            notificationType: "permission_prompt", message: nil))
        XCTAssertTrue(PermissionWatch.isPermissionRequest(
            notificationType: nil, message: "Claude needs your permission"))
        XCTAssertTrue(PermissionWatch.isPermissionRequest(
            notificationType: nil, message: "Claude needs your permission to use Write"))
        XCTAssertFalse(PermissionWatch.isPermissionRequest(
            notificationType: "idle_prompt", message: "Claude is waiting for your input"))
        XCTAssertFalse(PermissionWatch.isPermissionRequest(notificationType: nil, message: nil))
    }

    func testCodexApprovalRequestIsPermissionUnit() {
        XCTAssertTrue(PermissionWatch.isPermissionRequest(
            notificationType: "approval_request", message: nil))
        XCTAssertTrue(PermissionWatch.isPermissionRequest(
            notificationType: "approval_request", message: "Codex 请求权限"))
    }

    func testCodexApprovalPendingSurfaces() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 20_000, sessionId: "codex-s1",
                   cwd: "/Users/jalen/code/claudegotchi")
        try insert(id: "e2", type: "notification", ts: now - 3_000, sessionId: "codex-s1",
                   cwd: "/Users/jalen/code/claudegotchi",
                   message: "Codex 请求权限", notificationType: "approval_request")
        let pending = try PermissionWatch.pending(db: db, nowMs: now)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].sessionId, "codex-s1")
        XCTAssertEqual(pending[0].message, "Codex 请求权限")
        XCTAssertEqual(pending[0].repoName, "claudegotchi")
    }

    func testPendingRequestSurfacesWhenLatestEvent() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 20_000, sessionId: "s1",
                   cwd: "/Users/jalen/code/claudegotchi")
        try insert(id: "e2", type: "pre_tool_use", ts: now - 15_000, sessionId: "s1",
                   cwd: "/Users/jalen/code/claudegotchi")
        try insert(id: "e3", type: "notification", ts: now - 4_000, sessionId: "s1",
                   cwd: "/Users/jalen/code/claudegotchi",
                   message: "Claude needs your permission", notificationType: "permission_prompt")

        let pending = try PermissionWatch.pending(db: db, nowMs: now)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].sessionId, "s1")
        XCTAssertEqual(pending[0].repoName, "claudegotchi")
        XCTAssertEqual(pending[0].message, "Claude needs your permission")
        XCTAssertEqual(pending[0].ageMs, 4_000)
    }

    func testSupersededByLaterEventIsNotPending() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 20_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "notification", ts: now - 10_000, sessionId: "s1", cwd: "/tmp/r",
                   message: "Claude needs your permission", notificationType: "permission_prompt")
        // user approved → a later tool call supersedes the request
        try insert(id: "e3", type: "pre_tool_use", ts: now - 3_000, sessionId: "s1", cwd: "/tmp/r")

        XCTAssertTrue(try PermissionWatch.pending(db: db, nowMs: now).isEmpty)
    }

    func testIdlePromptIsNotPermission() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 20_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "notification", ts: now - 2_000, sessionId: "s1", cwd: "/tmp/r",
                   message: "Claude is waiting for your input", notificationType: "idle_prompt")
        XCTAssertTrue(try PermissionWatch.pending(db: db, nowMs: now).isEmpty)
    }

    func testMessagePrefixFallbackWithoutNotificationType() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 20_000, sessionId: "s1", cwd: "/tmp/legacy")
        try insert(id: "e2", type: "notification", ts: now - 1_000, sessionId: "s1", cwd: "/tmp/legacy",
                   message: "Claude needs your permission to use Bash")
        let pending = try PermissionWatch.pending(db: db, nowMs: now)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].repoName, "legacy")
    }

    func testOnlyLatestPermissionPerSession() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 30_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "notification", ts: now - 20_000, sessionId: "s1", cwd: "/tmp/r",
                   message: "Claude needs your permission", notificationType: "permission_prompt")
        try insert(id: "e3", type: "post_tool_use", ts: now - 15_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e4", type: "notification", ts: now - 2_000, sessionId: "s1", cwd: "/tmp/r",
                   message: "Claude needs your permission", notificationType: "permission_prompt")

        let pending = try PermissionWatch.pending(db: db, nowMs: now)
        XCTAssertEqual(pending.count, 1, "the superseded first request must not double-count")
        XCTAssertEqual(pending[0].ageMs, 2_000)
    }

    func testMultipleSessionsNewestFirst() throws {
        let now: Int64 = 1_000_000
        try insert(id: "a1", type: "session_start", ts: now - 30_000, sessionId: "old", cwd: "/tmp/a")
        try insert(id: "a2", type: "notification", ts: now - 9_000, sessionId: "old", cwd: "/tmp/a",
                   message: "Claude needs your permission", notificationType: "permission_prompt")
        try insert(id: "b1", type: "session_start", ts: now - 30_000, sessionId: "new", cwd: "/tmp/b")
        try insert(id: "b2", type: "notification", ts: now - 3_000, sessionId: "new", cwd: "/tmp/b",
                   message: "Claude needs your permission", notificationType: "permission_prompt")

        let pending = try PermissionWatch.pending(db: db, nowMs: now)
        XCTAssertEqual(pending.map(\.sessionId), ["new", "old"])
    }

    func testMaxAgeCutoffExcludesStale() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 400_000, sessionId: "s1", cwd: "/tmp/r")
        try insert(id: "e2", type: "notification", ts: now - 300_000, sessionId: "s1", cwd: "/tmp/r",
                   message: "Claude needs your permission", notificationType: "permission_prompt")
        XCTAssertTrue(try PermissionWatch.pending(db: db, nowMs: now, maxAgeMs: 60_000).isEmpty)
        XCTAssertEqual(try PermissionWatch.pending(db: db, nowMs: now, maxAgeMs: 600_000).count, 1)
    }

    func testFilterHidesPermissionByDirectory() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 20_000, sessionId: "s1", cwd: "/tmp/hookprobe/x")
        try insert(id: "e2", type: "notification", ts: now - 2_000, sessionId: "s1", cwd: "/tmp/hookprobe/x",
                   message: "Claude needs your permission", notificationType: "permission_prompt")
        try insert(id: "k1", type: "session_start", ts: now - 20_000, sessionId: "s2", cwd: "/tmp/repo")
        try insert(id: "k2", type: "notification", ts: now - 1_000, sessionId: "s2", cwd: "/tmp/repo",
                   message: "Claude needs your permission", notificationType: "permission_prompt")
        let filter = SessionFilter(directoryPatterns: ["/hookprobe"])
        let pending = try PermissionWatch.pending(db: db, nowMs: now, filter: filter)
        XCTAssertEqual(pending.map(\.sessionId), ["s2"], "hookprobe permission is filtered out")
    }

    func testCwdNilYieldsUnknownRepo() throws {
        let now: Int64 = 1_000_000
        try insert(id: "e1", type: "session_start", ts: now - 5_000, sessionId: "s1", cwd: nil)
        try insert(id: "e2", type: "notification", ts: now - 1_000, sessionId: "s1", cwd: nil,
                   message: "Claude needs your permission", notificationType: "permission_prompt")
        let pending = try PermissionWatch.pending(db: db, nowMs: now)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending[0].cwd)
        XCTAssertEqual(pending[0].repoName, "未知目录")
    }
}
