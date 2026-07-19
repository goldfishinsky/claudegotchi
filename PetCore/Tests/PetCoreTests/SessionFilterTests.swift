import XCTest
@testable import PetCore

final class SessionFilterTests: XCTestCase {
    func testEmptyFilterHidesNothing() {
        let f = SessionFilter.empty
        XCTAssertFalse(f.hides(cwd: "/Users/jalen/code/app", title: "修复登录"))
        XCTAssertFalse(f.hides(cwd: nil, title: nil))
        XCTAssertTrue(f.isEmpty)
    }

    func testDirectoryContainsMatch() {
        let f = SessionFilter(directoryPatterns: ["/hookprobe", "/.claude-mem"])
        XCTAssertTrue(f.hides(cwd: "/tmp/hookprobe/x", title: "任意"))
        XCTAssertTrue(f.hides(cwd: "/Users/jalen/.claude-mem/run", title: nil))
        XCTAssertFalse(f.hides(cwd: "/Users/jalen/code/claudegotchi", title: "干活"))
    }

    func testPromptPrefixMatchTrimmed() {
        let f = SessionFilter(promptPrefixPatterns: ["<task-notification>", "<command-name>"])
        XCTAssertTrue(f.hides(cwd: "/tmp/r", title: "<task-notification>done</task-notification>"))
        XCTAssertTrue(f.hides(cwd: "/tmp/r", title: "   <command-name>/init"))
        XCTAssertFalse(f.hides(cwd: "/tmp/r", title: "real work <task-notification> inside"))
        XCTAssertFalse(f.hides(cwd: "/tmp/r", title: "修复真正的 bug"))
    }

    func testCJKAndEmojiPrefixes() {
        let f = SessionFilter(promptPrefixPatterns: ["【机器人】", "🤖 "])
        XCTAssertTrue(f.hides(cwd: nil, title: "【机器人】自动回复"))
        XCTAssertTrue(f.hides(cwd: nil, title: "  🤖 生成中"))
        XCTAssertFalse(f.hides(cwd: nil, title: "人类的任务：改样式 🤖"))
    }

    func testEmptyPatternsIgnored() {
        let f = SessionFilter(directoryPatterns: ["", "  "], promptPrefixPatterns: [""])
        // Only truly empty strings are stripped; whitespace-only is kept but never
        // matches a real cwd meaningfully. Empty string patterns must not match all.
        XCTAssertFalse(f.hides(cwd: "/tmp/anything", title: "x"))
        XCTAssertEqual(f.directoryPatterns, ["  "])
        XCTAssertTrue(f.promptPrefixPatterns.isEmpty)
    }

    func testEitherListCanHide() {
        let f = SessionFilter(directoryPatterns: ["/probe"], promptPrefixPatterns: ["<noise>"])
        XCTAssertTrue(f.hides(cwd: "/x/probe/y", title: "human"))
        XCTAssertTrue(f.hides(cwd: "/clean", title: "<noise>ignore"))
        XCTAssertFalse(f.hides(cwd: "/clean", title: "human"))
    }

    func testPresetPromptPatternsMatchLegacyNoiseList() {
        XCTAssertEqual(
            SessionFilterPresets.promptPrefixPatterns,
            ["<task-notification>", "<local-command-caveat>", "<command-name>", "<system"],
            "title de-noising must stay identical after migrating to presets")
        XCTAssertEqual(AgentActivityTracker.titleNoisePrefixes, SessionFilterPresets.promptPrefixPatterns)
    }

    func testPresetInventory() {
        let dir = SessionFilterPresets.all.filter { $0.kind == .directory }.map(\.pattern)
        XCTAssertEqual(dir, ["/hookprobe", "/.claude-mem"])
        XCTAssertEqual(SessionFilterPresets.all.count, 6)
        XCTAssertEqual(Set(SessionFilterPresets.all.map(\.id)).count, 6, "preset ids are unique")
    }
}
