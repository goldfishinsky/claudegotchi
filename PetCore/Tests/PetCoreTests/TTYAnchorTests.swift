import XCTest
import GRDB
@testable import PetCore

final class TTYAnchorTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!
    var petId: Int64!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "tty-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
        petId = try Pet.insert(Pet.fresh(species: "frog", at: 0), into: db).id!
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func insert(id: String, type: String, ts: Int64, sessionId: String?, tty: String?) throws {
        var obj: [String: Any] = ["type": type, "ts": ts]
        if let sessionId { obj["session_id"] = sessionId }
        if let tty { obj["tty"] = tty }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO event (helper_event_id, ts, type, pet_id, payload, session_id, cwd)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """, arguments: [id, ts, type, petId!, String(data: data, encoding: .utf8), sessionId])
        }
    }

    func testStoredReturnsSessionStartTTY() throws {
        try insert(id: "e1", type: "session_start", ts: 100, sessionId: "s1", tty: "/dev/ttys004")
        try insert(id: "e2", type: "post_tool_use", ts: 200, sessionId: "s1", tty: nil)
        XCTAssertEqual(try TTYAnchor.stored(db: db, sessionId: "s1"), "/dev/ttys004")
    }

    func testStoredNilWhenSessionHeadless() throws {
        try insert(id: "e1", type: "session_start", ts: 100, sessionId: "s2", tty: nil)
        XCTAssertNil(try TTYAnchor.stored(db: db, sessionId: "s2"))
    }

    func testStoredNilForUnknownSession() throws {
        XCTAssertNil(try TTYAnchor.stored(db: db, sessionId: "nope"))
    }

    func testStoredPrefersLatestSessionStart() throws {
        try insert(id: "e1", type: "session_start", ts: 100, sessionId: "s3", tty: "/dev/ttys001")
        try insert(id: "e2", type: "session_start", ts: 300, sessionId: "s3", tty: "/dev/ttys009")
        XCTAssertEqual(try TTYAnchor.stored(db: db, sessionId: "s3"), "/dev/ttys009")
    }
}
