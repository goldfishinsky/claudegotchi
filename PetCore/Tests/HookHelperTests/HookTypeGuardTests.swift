import XCTest
@testable import HookHelper
import PetCore

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
        XCTAssertFalse(ClaudegotchiHook.rejectsRawType("user_prompt_submit"))
    }

    func testPromptTitlePassesShortPromptThrough() {
        XCTAssertEqual(ClaudegotchiHook.promptTitle(from: "修复登录按钮样式"), "修复登录按钮样式")
    }

    func testPromptTitleTruncatesAt120Graphemes() {
        let long = String(repeating: "永", count: 200)
        let title = ClaudegotchiHook.promptTitle(from: long)!
        XCTAssertEqual(title.count, 120, "grapheme-safe truncation to 120")
        XCTAssertEqual(title, String(repeating: "永", count: 120))
    }

    func testPromptTitleTruncationIsGraphemeSafe() {
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 200)
        let title = ClaudegotchiHook.promptTitle(from: emoji)!
        XCTAssertEqual(title.count, 120, "multi-scalar clusters counted as one grapheme")
        XCTAssertFalse(title.unicodeScalars.isEmpty)
    }

    func testPromptTitleStripsNewlines() {
        let title = ClaudegotchiHook.promptTitle(from: "第一行\n第二行\r\n第三行")
        XCTAssertEqual(title, "第一行 第二行 第三行")
        XCTAssertFalse(title!.contains("\n"))
        XCTAssertFalse(title!.contains("\r"))
    }

    func testPromptTitleNilOnEmptyOrWhitespace() {
        XCTAssertNil(ClaudegotchiHook.promptTitle(from: nil))
        XCTAssertNil(ClaudegotchiHook.promptTitle(from: "   \n  "))
    }

    func testRunUserPromptSubmitSpoolsTruncatedPromptWithNilTokensAndModel() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        let prompt = String(repeating: "字", count: 200)
        let stdin = #"{"session_id":"s","cwd":"/w","hook_event_name":"UserPromptSubmit","prompt":"\#(prompt)"}"#
        let code = ClaudegotchiHook.run(args: ["claudegotchi-hook", "user_prompt_submit"],
                                        stdin: stdin, spoolURL: spool)
        XCTAssertEqual(code, 0)
        let line = try String(contentsOf: spool).split(separator: "\n").first.map(String.init)!
        let event = try Event.parse(line)
        XCTAssertEqual(event.type, .userPromptSubmit)
        XCTAssertEqual(event.sessionId, "s")
        XCTAssertEqual(event.prompt?.count, 120)
        XCTAssertNil(event.tokensIn)
        XCTAssertNil(event.tokensOut)
        XCTAssertNil(event.model)
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

    func testParsePayloadReadsNestedTokensShape() {
        let p = ClaudegotchiHook.parsePayload(#"{"tokens":{"input":40,"output":9},"model":"opus"}"#)
        XCTAssertEqual(p["tokens_in"] as? Int, 40)
        XCTAssertEqual(p["tokens_out"] as? Int, 9)
    }

    func testParsePayloadFlatTokensWinWhenNoNested() {
        let p = ClaudegotchiHook.parsePayload(#"{"tokens_in":7,"tokens_out":3}"#)
        XCTAssertEqual(p["tokens_in"] as? Int, 7)
        XCTAssertEqual(p["tokens_out"] as? Int, 3)
    }

    func testRunStopDerivesTokensAndModelFromTranscript() throws {
        let spool = tempSpoolURL()
        let cursorDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cur-\(UUID())")
        let tp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tr-\(UUID()).jsonl")
        defer {
            try? FileManager.default.removeItem(at: spool)
            try? FileManager.default.removeItem(at: cursorDir)
            try? FileManager.default.removeItem(at: tp)
        }
        let transcript = [
            #"{"type":"assistant","message":{"id":"msg_A","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"cache_creation_input_tokens":9667,"output_tokens":116}}}"#,
            #"{"type":"assistant","message":{"id":"msg_B","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":8,"cache_creation_input_tokens":191,"output_tokens":38}}}"#,
        ].joined(separator: "\n")
        try transcript.write(to: tp, atomically: true, encoding: .utf8)
        // Pre-seed cursor as if msg_A was already counted on a prior turn.
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        try "msg_A".write(to: cursorDir.appendingPathComponent("sess-xyz"), atomically: true, encoding: .utf8)

        // Real Claude Code 2.1.211 Stop stdin: no tokens, no model — only transcript_path.
        let stdin = #"{"session_id":"sess-xyz","transcript_path":"\#(tp.path)","cwd":"/w","hook_event_name":"Stop","stop_hook_active":false}"#
        let code = ClaudegotchiHook.run(args: ["claudegotchi-hook", "stop"], stdin: stdin,
                                        spoolURL: spool, cursorDir: cursorDir)
        XCTAssertEqual(code, 0)

        let line = try String(contentsOf: spool).split(separator: "\n").first.map(String.init)!
        let event = try Event.parse(line)
        XCTAssertEqual(event.type, .stop)
        XCTAssertEqual(event.tokensIn, 199, "input(8)+cache_creation(191) of the one new message")
        XCTAssertEqual(event.tokensOut, 38)
        XCTAssertEqual(event.model, "claude-haiku-4-5-20251001")
    }

    func testRunStopFirstSightSpoolsZeroTokens() throws {
        let spool = tempSpoolURL()
        let cursorDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cur-\(UUID())")
        let tp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tr-\(UUID()).jsonl")
        defer {
            try? FileManager.default.removeItem(at: spool)
            try? FileManager.default.removeItem(at: cursorDir)
            try? FileManager.default.removeItem(at: tp)
        }
        try #"{"type":"assistant","message":{"id":"msg_A","usage":{"input_tokens":10,"output_tokens":116}}}"#
            .write(to: tp, atomically: true, encoding: .utf8)
        let stdin = #"{"session_id":"fresh","transcript_path":"\#(tp.path)","hook_event_name":"Stop"}"#
        _ = ClaudegotchiHook.run(args: ["claudegotchi-hook", "stop"], stdin: stdin,
                                 spoolURL: spool, cursorDir: cursorDir)
        let event = try Event.parse(String(try String(contentsOf: spool).split(separator: "\n")[0]))
        XCTAssertEqual(event.tokensIn, 0, "first sight of a session resyncs and emits nothing")
        XCTAssertEqual(event.tokensOut, 0)
    }

    func testRunNotificationSpoolsMessageAndType() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        let stdin = #"{"session_id":"s","cwd":"/w","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#
        let code = ClaudegotchiHook.run(args: ["claudegotchi-hook", "notification"],
                                        stdin: stdin, spoolURL: spool)
        XCTAssertEqual(code, 0)
        let line = try String(contentsOf: spool).split(separator: "\n").first.map(String.init)!
        let event = try Event.parse(line)
        XCTAssertEqual(event.type, .notification)
        XCTAssertEqual(event.message, "Claude needs your permission")
        XCTAssertEqual(event.notificationType, "permission_prompt")
        XCTAssertEqual(event.cwd, "/w")
    }

    func testNotificationMessageTruncatesAt200() {
        let long = String(repeating: "字", count: 300)
        let msg = ClaudegotchiHook.notificationMessage(from: long)!
        XCTAssertEqual(msg.count, 200)
        XCTAssertEqual(msg, String(repeating: "字", count: 200))
    }

    func testNotificationMessageFlattensAndTrimsNilOnEmpty() {
        XCTAssertEqual(ClaudegotchiHook.notificationMessage(from: "第一行\n第二行"), "第一行 第二行")
        XCTAssertNil(ClaudegotchiHook.notificationMessage(from: "   \n "))
        XCTAssertNil(ClaudegotchiHook.notificationMessage(from: nil))
    }

    func testNonNotificationDropsMessageField() throws {
        let spool = tempSpoolURL()
        defer { try? FileManager.default.removeItem(at: spool) }
        let stdin = #"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Bash","message":"stray"}"#
        _ = ClaudegotchiHook.run(args: ["claudegotchi-hook", "post_tool_use"], stdin: stdin, spoolURL: spool)
        let event = try Event.parse(String(try String(contentsOf: spool).split(separator: "\n")[0]))
        XCTAssertNil(event.message, "message is captured only for notification events")
        XCTAssertNil(event.notificationType)
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
