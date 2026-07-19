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

    // MARK: - Codex platform

    private let vibeCmd = "'/Users/jalen/.vibe-island/bin/vibe-island-bridge' --source codex"

    // Mirrors the real ~/.codex/hooks.json shape observed on this machine.
    private func vibeIslandFixture() -> String {
        """
        {"hooks":{
          "PermissionRequest":[{"hooks":[{"command":"\(vibeCmd)","timeout":7200,"type":"command"}]}],
          "PostToolUse":[{"hooks":[{"command":"\(vibeCmd)","timeout":5,"type":"command"}],"matcher":""}],
          "SessionStart":[{"hooks":[{"command":"\(vibeCmd)","timeout":5,"type":"command"}]}],
          "Stop":[{"hooks":[{"command":"\(vibeCmd)","timeout":5,"type":"command"}]}],
          "SubagentStop":[{"hooks":[{"command":"\(vibeCmd)","timeout":5,"type":"command"}]}],
          "UserPromptSubmit":[{"hooks":[{"command":"\(vibeCmd)","timeout":5,"type":"command"}]}]
        }}
        """
    }

    private func foreignCommandCount(_ root: [String: Any], _ command: String) -> Int {
        guard let hooks = root["hooks"] as? [String: Any] else { return 0 }
        var n = 0
        for (_, v) in hooks {
            guard let groups = v as? [[String: Any]] else { continue }
            for g in groups {
                for leaf in (g["hooks"] as? [[String: Any]]) ?? [] where leaf["command"] as? String == command {
                    n += 1
                }
            }
        }
        return n
    }

    func testCodexInstallMergesAlongsideVibeIslandAndTags() throws {
        try vibeIslandFixture().data(using: .utf8)!.write(to: settings)
        try HooksInstaller.install(platform: .codex, settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)

        XCTAssertEqual(try HooksInstaller.status(platform: .codex, settingsPath: settings), .installed)
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 6, "6 tagged codex leaves added")
        XCTAssertEqual(foreignCommandCount(try loadJSON(), vibeCmd), 6, "all Vibe Island leaves preserved")

        // SubagentStop is not one of ours → retains only Vibe Island's leaf, untouched.
        let sub = (try hooks())["SubagentStop"] as! [[String: Any]]
        let subLeaves = sub.flatMap { ($0["hooks"] as! [[String: Any]]) }
        XCTAssertEqual(subLeaves.count, 1)
        XCTAssertEqual(subLeaves[0]["command"] as? String, vibeCmd)

        // PostToolUse now has two groups: Vibe Island's + ours.
        let post = (try hooks())["PostToolUse"] as! [[String: Any]]
        XCTAssertEqual(post.count, 2, "our tagged group appended beside the foreign one")
    }

    func testCodexTaggedLeavesCarryTimeoutFiveAndCodexArgs() throws {
        try HooksInstaller.install(platform: .codex, settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        let h = try hooks()
        for (event, expectedArg) in [
            ("SessionStart", "codex_session_start"), ("Stop", "codex_stop"),
            ("PermissionRequest", "codex_permission_request"), ("PreToolUse", "codex_pre_tool_use"),
        ] {
            let groups = h[event] as! [[String: Any]]
            let ours = groups.flatMap { ($0["hooks"] as! [[String: Any]]) }
                .first { $0["_claudegotchi"] as? Bool == true }!
            XCTAssertEqual(ours["timeout"] as? Int, 5, "\(event) timeout must be 5")
            XCTAssertTrue((ours["command"] as! String).contains(expectedArg), "\(event) command carries \(expectedArg)")
        }
    }

    func testCodexUninstallRemovesOnlyTaggedPreservingVibeIsland() throws {
        try vibeIslandFixture().data(using: .utf8)!.write(to: settings)
        try HooksInstaller.install(platform: .codex, settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        try HooksInstaller.uninstall(platform: .codex, settingsPath: settings)

        XCTAssertEqual(taggedLeafCount(try loadJSON()), 0, "our tagged leaves removed")
        XCTAssertEqual(foreignCommandCount(try loadJSON(), vibeCmd), 6, "Vibe Island fully preserved")
        XCTAssertEqual(try HooksInstaller.status(platform: .codex, settingsPath: settings), .notInstalled)
    }

    func testCodexInstallIdempotent() throws {
        try vibeIslandFixture().data(using: .utf8)!.write(to: settings)
        try HooksInstaller.install(platform: .codex, settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        try HooksInstaller.install(platform: .codex, settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 6, "second install must not duplicate")
        XCTAssertEqual(foreignCommandCount(try loadJSON(), vibeCmd), 6)
    }

    func testClaudeInstallDoesNotWriteCodexArgs() throws {
        let codexSettings = dir.appendingPathComponent("hooks.json")
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        try HooksInstaller.install(platform: .codex, settingsPath: codexSettings, hookBinaryPath: bin, nowISO: nowISO)
        XCTAssertEqual(try HooksInstaller.status(settingsPath: settings), .installed)
        XCTAssertEqual(try HooksInstaller.status(platform: .codex, settingsPath: codexSettings), .installed)
        XCTAssertFalse(try String(contentsOf: settings).contains("codex_"), "claude file has no codex args")
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
