import XCTest
import GRDB
@testable import PetCore

final class SpoolWatcherTests: XCTestCase {
    var dbPath: String!
    var db: DatabaseQueue!
    var spoolDir: URL!
    var spoolURL: URL!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "watcher-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
        _ = try Pet.insert(.fresh(species: "frog", at: 0), into: db)
        spoolDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spool-\(UUID())")
        try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
        spoolURL = spoolDir.appendingPathComponent("spool.jsonl")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(at: spoolDir)
    }

    private func appendToFile(_ s: String, at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((s + "\n").utf8))
        try h.close()
    }

    private func appendLine(_ s: String) throws {
        try appendToFile(s, at: spoolURL)
    }

    private func makeWatcher(paused: Bool = false) -> SpoolWatcher {
        SpoolWatcher(
            db: db,
            applier: EventApplier(config: .defaults),
            spoolURL: spoolURL,
            spoolLockURL: spoolDir.appendingPathComponent("spool.lock"),
            pausedProvider: { paused },
            config: .defaults
        )
    }

    private func eventLine(eventId: String) throws -> String {
        let e = Event(
            schemaVersion: 1, eventId: eventId,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            type: .postToolUse, sessionId: "s", tool: "Bash",
            tokensIn: 100, tokensOut: 100, model: nil
        )
        return try e.encodeJSON()
    }

    func testPumpDrainsAvailableLines() throws {
        try appendLine(try eventLine(eventId: "01H0000000000000000000000A"))
        try appendLine(try eventLine(eventId: "01H0000000000000000000000B"))
        let w = makeWatcher()
        try w.pump()
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 2)
    }

    func testRotationRenamesAndDrains() throws {
        var cfg = ConfigYAML.defaults
        cfg = ConfigYAML(
            decay: cfg.decay, eventCosts: cfg.eventCosts, thresholds: cfg.thresholds,
            spool: ConfigYAML.Spool(rotateWhenBytesExceed: 100, rotateWhenAgeExceedsSeconds: 999_999)
        )
        let w = SpoolWatcher(
            db: db, applier: EventApplier(config: cfg),
            spoolURL: spoolURL,
            spoolLockURL: spoolDir.appendingPathComponent("spool.lock"),
            pausedProvider: { false }, config: cfg
        )
        for i in 0..<3 {
            let id = String(format: "01H000000000000000000000%02d", i)
            try appendLine(try eventLine(eventId: id))
        }
        try w.pump()
        try w.maybeRotate()
        try w.pump()

        let entries = try FileManager.default.contentsOfDirectory(
            at: spoolDir, includingPropertiesForKeys: nil
        )
        let baks = entries.filter { $0.lastPathComponent.contains(".bak") }
        XCTAssertEqual(baks.count, 0)
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event") }
        XCTAssertEqual(count, 3)
    }

    func testPumpHonorsPause() throws {
        try appendLine(try eventLine(eventId: "01H0000000000000000000000A"))
        let w = makeWatcher(paused: true)
        try w.pump()
        let p = try Pet.fetchAlive(from: db)!
        XCTAssertEqual(p.xp, 0)
        XCTAssertGreaterThan(p.lastAppliedEventId, 0)
    }
}
