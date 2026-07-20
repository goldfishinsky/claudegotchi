import XCTest
@testable import HookHelper
import PetCore

final class ControllingTTYTests: XCTestCase {
    private func tempSpoolURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spool-\(UUID().uuidString).jsonl")
    }

    private func spoolLine(_ url: URL) throws -> String {
        try String(contentsOf: url).split(separator: "\n").first.map(String.init) ?? ""
    }

    private func spoolEvent(_ url: URL) throws -> Event {
        try Event.parse(spoolLine(url))
    }

    func testResolvePrefersOwnTTY() {
        let tty = ControllingTTY.resolve(pid: 10, ppid: 20) { $0 == 10 ? "/dev/ttys004" : "/dev/ttys009" }
        XCTAssertEqual(tty, "/dev/ttys004")
    }

    func testResolveFallsBackToParentWhenHookDetached() {
        // The detached hook has no controlling tty; the parent CLI process does.
        let tty = ControllingTTY.resolve(pid: 10, ppid: 20) { $0 == 20 ? "/dev/ttys001" : nil }
        XCTAssertEqual(tty, "/dev/ttys001", "a setsid'd hook anchors from its parent's terminal")
    }

    func testResolveNilWhenBothHeadless() {
        XCTAssertNil(ControllingTTY.resolve(pid: 10, ppid: 20) { _ in nil })
    }

    func testResolveDoesNotProbeLaunchdParent() {
        var probed: [Int32] = []
        let tty = ControllingTTY.resolve(pid: 10, ppid: 1) { probed.append($0); return nil }
        XCTAssertNil(tty)
        XCTAssertEqual(probed, [10], "ppid 1 (launchd) is never a session terminal, so skip it")
    }

    func testSessionStartRecordsTTY() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "session_start"],
            stdin: #"{"session_id":"s1","cwd":"/w/repo"}"#,
            spoolURL: spool, controllingTTY: "/dev/ttys005")
        XCTAssertEqual(try spoolEvent(spool).tty, "/dev/ttys005")
    }

    func testNonSessionStartAlsoRecordsTTY() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "stop"],
            stdin: #"{"session_id":"s1"}"#,
            spoolURL: spool, controllingTTY: "/dev/ttys005")
        XCTAssertEqual(try spoolEvent(spool).tty, "/dev/ttys005",
                       "every resolvable event anchors the tty, not just session_start")
    }

    func testHeadlessNonSessionStartRecordsNoTTY() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "post_tool_use"],
            stdin: #"{"session_id":"s1","tool_name":"Bash"}"#,
            spoolURL: spool, controllingTTY: nil)
        XCTAssertFalse(try spoolLine(spool).contains("tty"))
    }

    func testHeadlessSessionStartRecordsNoTTY() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "session_start"],
            stdin: #"{"session_id":"s1"}"#,
            spoolURL: spool, controllingTTY: nil)
        XCTAssertFalse(try spoolLine(spool).contains("tty"))
    }

    func testTitleInjectedOnSessionStart() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        var writes: [(String, String)] = []
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "session_start"],
            stdin: #"{"session_id":"4163ffb0-4f9b","cwd":"/Users/jalen/code/claudegotchi"}"#,
            spoolURL: spool, controllingTTY: "/dev/ttys005",
            titleMarkersEnabled: true, titleWriter: { writes.append(($0, $1)) })
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.1, "/dev/ttys005")
        XCTAssertEqual(writes.first?.0, "\u{1b}]0;❖4163ff claudegotchi\u{07}")
    }

    func testTitleInjectedOnUserPromptSubmit() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        var writes: [(String, String)] = []
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "user_prompt_submit"],
            stdin: #"{"session_id":"abcdef00","cwd":"/w/repo","prompt":"hi"}"#,
            spoolURL: spool, controllingTTY: "/dev/ttys006",
            titleMarkersEnabled: true, titleWriter: { writes.append(($0, $1)) })
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "\u{1b}]0;❖abcdef repo\u{07}")
    }

    func testTitleNotInjectedOnOtherEvents() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        var writes: [(String, String)] = []
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "post_tool_use"],
            stdin: #"{"session_id":"s1","cwd":"/w/repo","tool_name":"Bash"}"#,
            spoolURL: spool, controllingTTY: "/dev/ttys006",
            titleMarkersEnabled: true, titleWriter: { writes.append(($0, $1)) })
        XCTAssertTrue(writes.isEmpty)
    }

    func testTitleNotInjectedWhenDisabled() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        var writes: [(String, String)] = []
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "session_start"],
            stdin: #"{"session_id":"s1","cwd":"/w/repo"}"#,
            spoolURL: spool, controllingTTY: "/dev/ttys006",
            titleMarkersEnabled: false, titleWriter: { writes.append(($0, $1)) })
        XCTAssertTrue(writes.isEmpty)
    }

    func testTitleNotInjectedWhenHeadless() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        var writes: [(String, String)] = []
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "session_start"],
            stdin: #"{"session_id":"s1","cwd":"/w/repo"}"#,
            spoolURL: spool, controllingTTY: nil,
            titleMarkersEnabled: true, titleWriter: { writes.append(($0, $1)) })
        XCTAssertTrue(writes.isEmpty)
    }

    func testCodexSessionStartTokenStripsNamespaceAndAnchorsTTY() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        var writes: [(String, String)] = []
        _ = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "codex_session_start"],
            stdin: #"{"session_id":"deadbeef-1234","cwd":"/w/proj"}"#,
            spoolURL: spool, controllingTTY: "/dev/ttys007",
            titleMarkersEnabled: true, titleWriter: { writes.append(($0, $1)) })
        XCTAssertEqual(writes.first?.0, "\u{1b}]0;❖deadbe proj\u{07}")
        let event = try spoolEvent(spool)
        XCTAssertEqual(event.tty, "/dev/ttys007")
        XCTAssertEqual(event.sessionId, "codex-deadbeef-1234")
    }
}
