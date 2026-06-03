import XCTest
@testable import HookHelper

final class HookTypeGuardTests: XCTestCase {
    func testCwdReadFromPayload() {
        let cwd = ClaudegotchiHook.cwdFromPayload(#"{"cwd":"/tmp/work","session_id":"s"}"#)
        XCTAssertEqual(cwd, "/tmp/work")
    }

    func testCwdNilWhenAbsent() {
        XCTAssertNil(ClaudegotchiHook.cwdFromPayload(#"{"session_id":"s"}"#))
        XCTAssertNil(ClaudegotchiHook.cwdFromPayload(nil))
    }

    func testRejectsPrApprovedRawType() {
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pr_approved"))
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pr_merged"))
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pr_anything"))
    }

    func testAcceptsKnownHookType() {
        XCTAssertFalse(ClaudegotchiHook.rejectsRawType("session_start"))
        XCTAssertFalse(ClaudegotchiHook.rejectsRawType("post_tool_use"))
        XCTAssertFalse(ClaudegotchiHook.rejectsRawType("notification"))
    }

    func testRejectsPetAndPrPrefixRawType() {
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pet_click"))
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pet_anything"))
        XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pr_approved"))
        XCTAssertFalse(ClaudegotchiHook.rejectsRawType("session_start"))
    }

    func testParsePayloadMapsToolNameToTool() {
        let p = ClaudegotchiHook.parsePayload(#"{"session_id":"s","cwd":"/w","tool_name":"Bash","model":"opus","tokens_in":10,"tokens_out":20}"#)
        XCTAssertEqual(p["session_id"] as? String, "s")
        XCTAssertEqual(p["cwd"] as? String, "/w")
        XCTAssertEqual(p["tool"] as? String, "Bash")
        XCTAssertEqual(p["model"] as? String, "opus")
        XCTAssertEqual(p["tokens_in"] as? Int, 10)
        XCTAssertEqual(p["tokens_out"] as? Int, 20)
    }

    func testParsePayloadEmptyOnNilOrMalformed() {
        XCTAssertTrue(ClaudegotchiHook.parsePayload(nil).isEmpty)
        XCTAssertTrue(ClaudegotchiHook.parsePayload("not json").isEmpty)
    }

    private func tempSpoolURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spool-\(UUID()).jsonl")
    }

    func testRunRejectsAppInternalTypeWithExitZero() {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        let code = ClaudegotchiHook.run(args: ["claudegotchi-hook", "pet_click"], stdin: nil, spoolURL: spool)
        XCTAssertEqual(code, 0, "app-internal type must never block a tool call")
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path), "rejected type must not be spooled")
    }

    func testRunEmptyStdinSpoolsTypeOnlyEventExitZero() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        let code = ClaudegotchiHook.run(args: ["claudegotchi-hook", "session_start"], stdin: nil, spoolURL: spool)
        XCTAssertEqual(code, 0)
        let lines = try String(contentsOf: spool).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "empty stdin still emits one type-only event")
        XCTAssertTrue(lines[0].contains("session_start"))
    }

    func testRunWithPayloadExitZero() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        let code = ClaudegotchiHook.run(
            args: ["claudegotchi-hook", "post_tool_use"],
            stdin: #"{"tool_name":"Bash","model":"opus","tokens_in":1,"tokens_out":2}"#,
            spoolURL: spool
        )
        XCTAssertEqual(code, 0)
        let lines = try String(contentsOf: spool).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("post_tool_use"))
        XCTAssertTrue(lines[0].contains("Bash"))
    }
}
