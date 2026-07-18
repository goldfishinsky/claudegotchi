import XCTest
@testable import PetCore

final class HooksInstallerTests: XCTestCase {
    var dir: URL!
    var settings: URL!
    let nowISO = "2026-06-03T00:00:00Z"
    let bin = "/Users/jalen/Library/Application Support/claudegotchi/bin/claudegotchi-hook"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hooks-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func loadJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: settings)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func hooks() throws -> [String: Any] {
        (try loadJSON())["hooks"] as! [String: Any]
    }

    private func taggedLeafCount(_ root: [String: Any]) -> Int {
        guard let hooks = root["hooks"] as? [String: Any] else { return 0 }
        var n = 0
        for (_, v) in hooks {
            guard let groups = v as? [[String: Any]] else { continue }
            for g in groups {
                for leaf in (g["hooks"] as? [[String: Any]]) ?? [] where leaf["_claudegotchi"] as? Bool == true {
                    n += 1
                }
            }
        }
        return n
    }

    func testFreshInstallWritesSixTaggedLeaves() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 6)
        let h = try hooks()
        for key in ["PreToolUse", "PostToolUse", "SessionStart", "UserPromptSubmit", "Stop", "Notification"] {
            XCTAssertNotNil(h[key], "missing \(key)")
        }
        let ups = (h["UserPromptSubmit"] as! [[String: Any]]).first!
        XCTAssertNil(ups["matcher"], "UserPromptSubmit is a matcher-less event")
        let pre = (h["PreToolUse"] as! [[String: Any]]).first!
        XCTAssertEqual(pre["matcher"] as? String, "*")
        let ss = (h["SessionStart"] as! [[String: Any]]).first!
        XCTAssertNil(ss["matcher"])
    }

    func testCommandReParsesWithSpaceInPath() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        let leaf = ((try hooks()["SessionStart"] as! [[String: Any]]).first!["hooks"] as! [[String: Any]]).first!
        let cmd = leaf["command"] as! String
        XCTAssertTrue(cmd.contains("session_start"))
        XCTAssertTrue(cmd.hasPrefix("'\(bin)'"), "path must be single-quoted: \(cmd)")
    }

    func testMergePreservesForeignKeysAndGroups() throws {
        let existing = """
        {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/bin/foreign"}]}]}}
        """
        try existing.data(using: .utf8)!.write(to: settings)
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        let root = try loadJSON()
        XCTAssertEqual(root["model"] as? String, "opus", "foreign top-level key kept")
        let pre = (try hooks())["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 2, "foreign group kept; ours appended")
        XCTAssertEqual(taggedLeafCount(root), 6)
    }

    func testCorruptJSONRefused() throws {
        try "{ not json".data(using: .utf8)!.write(to: settings)
        XCTAssertThrowsError(try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO))
        let raw = try String(contentsOf: settings)
        XCTAssertEqual(raw, "{ not json", "corrupt file left intact")
    }

    func testIdempotentNoDuplicate() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 6, "second install must not duplicate")
    }

    func testReinstallUpdatesCommandInPlace() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        let newBin = "/new/path/claudegotchi-hook"
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: newBin, nowISO: nowISO)
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 6)
        let leaf = (((try hooks())["Stop"] as! [[String: Any]]).first!["hooks"] as! [[String: Any]]).first!
        XCTAssertTrue((leaf["command"] as! String).hasPrefix("'\(newBin)'"))
    }

    func testStatusTransitions() throws {
        XCTAssertEqual(try HooksInstaller.status(settingsPath: settings), .notInstalled)
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        XCTAssertEqual(try HooksInstaller.status(settingsPath: settings), .installed)
        try HooksInstaller.uninstall(settingsPath: settings)
        XCTAssertEqual(try HooksInstaller.status(settingsPath: settings), .notInstalled)
    }

    func testUninstallSharedGroupAndForeignSiblingAndUntaggedSamePath() throws {
        let existing = """
        {"hooks":{"PreToolUse":[
          {"matcher":"Bash","hooks":[{"type":"command","command":"/usr/bin/foreign"}]},
          {"matcher":"*","hooks":[
            {"type":"command","command":"/other/tool"},
            {"type":"command","command":"'\(bin)' pre_tool_use"}
          ]}
        ]}}
        """
        try existing.data(using: .utf8)!.write(to: settings)
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        try HooksInstaller.uninstall(settingsPath: settings)
        let pre = (try hooks())["PreToolUse"] as! [[String: Any]]
        let allLeafCommands = pre.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
        XCTAssertTrue(allLeafCommands.contains("/usr/bin/foreign"))
        XCTAssertTrue(allLeafCommands.contains("/other/tool"))
        XCTAssertTrue(allLeafCommands.contains("'\(bin)' pre_tool_use"), "untagged same-path leaf must NOT be removed")
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 0, "all tagged leaves removed")
    }

    func testWrittenJSONParsesAsMatcherGroupShape() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        for (_, v) in try hooks() {
            let groups = v as! [[String: Any]]
            for g in groups {
                for leaf in (g["hooks"] as! [[String: Any]]) {
                    XCTAssertEqual(leaf["type"] as? String, "command")
                    XCTAssertNotNil(leaf["command"] as? String)
                }
            }
        }
    }
}
