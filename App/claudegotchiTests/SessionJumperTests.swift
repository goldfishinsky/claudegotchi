import XCTest
@testable import claudegotchi

private struct MockEnv: TerminalEnvironment {
    var axTrusted: Bool
    var running: [String]
    var windowMatch: String?
    private(set) var scanned = false

    func runningTerminalBundleIDs() -> [String] { running }
    func windowBundleID(matching targets: [String]) -> String? { windowMatch }
}

final class SessionJumperTests: XCTestCase {
    func testMatchTargetsBasenameAndLastTwo() {
        XCTAssertEqual(
            TerminalJumpPlanner.matchTargets(cwd: "/Users/jalen/Documents/code/claudegotchi"),
            ["claudegotchi", "code/claudegotchi"])
        XCTAssertEqual(TerminalJumpPlanner.matchTargets(cwd: "/tmp/"), ["tmp"])
        XCTAssertEqual(TerminalJumpPlanner.matchTargets(cwd: ""), [])
    }

    func testTitleMatchesCaseInsensitiveContains() {
        let targets = TerminalJumpPlanner.matchTargets(cwd: "/Users/jalen/code/claudegotchi")
        XCTAssertTrue(TerminalJumpPlanner.titleMatches("jalen — claudegotchi — zsh", targets: targets))
        XCTAssertTrue(TerminalJumpPlanner.titleMatches("~/code/claudegotchi", targets: targets))
        XCTAssertTrue(TerminalJumpPlanner.titleMatches("CLAUDEGOTCHI", targets: targets))
        XCTAssertFalse(TerminalJumpPlanner.titleMatches("some-other-repo", targets: targets))
        XCTAssertFalse(TerminalJumpPlanner.titleMatches("anything", targets: []))
    }

    func testShouldPromptAXOnlyFirstTimeWithoutTrust() {
        XCTAssertTrue(TerminalJumpPlanner.shouldPromptAX(axTrusted: false, alreadyPrompted: false))
        XCTAssertFalse(TerminalJumpPlanner.shouldPromptAX(axTrusted: false, alreadyPrompted: true))
        XCTAssertFalse(TerminalJumpPlanner.shouldPromptAX(axTrusted: true, alreadyPrompted: false))
    }

    func testTier1RaisesWindowWhenTrustedAndMatched() {
        let env = MockEnv(axTrusted: true, running: ["com.apple.Terminal"], windowMatch: "com.googlecode.iterm2")
        XCTAssertEqual(
            TerminalJumpPlanner.plan(cwd: "/w/repo", env: env),
            .raiseWindow(bundleID: "com.googlecode.iterm2"))
    }

    func testTier2ActivatesWhenTrustedButNoWindowMatch() {
        let env = MockEnv(axTrusted: true, running: ["com.apple.Terminal", "org.alacritty"], windowMatch: nil)
        XCTAssertEqual(
            TerminalJumpPlanner.plan(cwd: "/w/repo", env: env),
            .activateApp(bundleID: "com.apple.Terminal"))
    }

    func testTier2ActivatesWhenNoAXEvenIfAWindowWouldMatch() {
        // window scan must be skipped when AX is untrusted → activation tier
        let env = MockEnv(axTrusted: false, running: ["dev.warp.Warp-Stable"], windowMatch: "com.apple.Terminal")
        XCTAssertEqual(
            TerminalJumpPlanner.plan(cwd: "/w/repo", env: env),
            .activateApp(bundleID: "dev.warp.Warp-Stable"))
    }

    func testTier3OpensWhenNothingRunning() {
        let env = MockEnv(axTrusted: true, running: [], windowMatch: nil)
        XCTAssertEqual(TerminalJumpPlanner.plan(cwd: "/w/repo", env: env), .openInTerminal)

        let envNoAX = MockEnv(axTrusted: false, running: [], windowMatch: nil)
        XCTAssertEqual(TerminalJumpPlanner.plan(cwd: "/w/repo", env: envNoAX), .openInTerminal)
    }

    func testDecideIgnoresWindowMatchWhenUntrusted() {
        XCTAssertEqual(
            TerminalJumpPlanner.decide(JumpContext(
                axTrusted: false, matchedWindowBundleID: "com.apple.Terminal",
                runningTerminalBundleIDs: [])),
            .openInTerminal)
    }
}
