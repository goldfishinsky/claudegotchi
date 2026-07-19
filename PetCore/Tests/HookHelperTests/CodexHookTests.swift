import XCTest
@testable import HookHelper
import PetCore

final class CodexHookTests: XCTestCase {
    private func tempSpoolURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spool-\(UUID()).jsonl")
    }

    private func firstEvent(_ spool: URL) throws -> Event {
        try Event.parse(String(try String(contentsOf: spool).split(separator: "\n")[0]))
    }

    func testIsCodexArgAndInternalTypeMapping() {
        XCTAssertTrue(ClaudegotchiHook.isCodexArg("codex_stop"))
        XCTAssertFalse(ClaudegotchiHook.isCodexArg("stop"))
        XCTAssertEqual(ClaudegotchiHook.internalType(forArg: "codex_session_start"), "session_start")
        XCTAssertEqual(ClaudegotchiHook.internalType(forArg: "codex_user_prompt_submit"), "user_prompt_submit")
        XCTAssertEqual(ClaudegotchiHook.internalType(forArg: "codex_pre_tool_use"), "pre_tool_use")
        XCTAssertEqual(ClaudegotchiHook.internalType(forArg: "codex_post_tool_use"), "post_tool_use")
        XCTAssertEqual(ClaudegotchiHook.internalType(forArg: "codex_permission_request"), "notification")
        XCTAssertEqual(ClaudegotchiHook.internalType(forArg: "stop"), "stop", "claude arg is unchanged")
    }

    func testCodexSessionStartNamespacesSessionIdAndSetsPlatform() throws {
        let spool = tempSpoolURL(); defer { try? FileManager.default.removeItem(at: spool) }
        let stdin = #"{"session_id":"019eb7bc-uuid","cwd":"/w","hook_event_name":"SessionStart","model":"gpt-5-codex"}"#
        XCTAssertEqual(ClaudegotchiHook.run(args: ["claudegotchi-hook", "codex_session_start"], stdin: stdin, spoolURL: spool), 0)
        let e = try firstEvent(spool)
        XCTAssertEqual(e.type, .sessionStart)
        XCTAssertEqual(e.sessionId, "codex-019eb7bc-uuid")
        XCTAssertEqual(e.platform, "codex")
        XCTAssertEqual(e.model, "gpt-5-codex")
    }

    func testClaudeSessionStartUnaffectedNoPlatformNoNamespace() throws {
        let spool = tempSpoolURL(); defer { try? FileManager.default.removeItem(at: spool) }
        let stdin = #"{"session_id":"abc","cwd":"/w","hook_event_name":"SessionStart"}"#
        _ = ClaudegotchiHook.run(args: ["claudegotchi-hook", "session_start"], stdin: stdin, spoolURL: spool)
        let e = try firstEvent(spool)
        XCTAssertEqual(e.sessionId, "abc")
        XCTAssertNil(e.platform)
    }

    func testCodexPermissionRequestMapsToApprovalNotification() throws {
        let spool = tempSpoolURL(); defer { try? FileManager.default.removeItem(at: spool) }
        let stdin = #"{"session_id":"u1","cwd":"/w","hook_event_name":"PermissionRequest","model":"gpt-5-codex","message":"Run rm -rf?"}"#
        _ = ClaudegotchiHook.run(args: ["claudegotchi-hook", "codex_permission_request"], stdin: stdin, spoolURL: spool)
        let e = try firstEvent(spool)
        XCTAssertEqual(e.type, .notification)
        XCTAssertEqual(e.notificationType, "approval_request")
        XCTAssertEqual(e.message, "Run rm -rf?")
        XCTAssertEqual(e.sessionId, "codex-u1")
        XCTAssertEqual(e.platform, "codex")
    }

    func testCodexPermissionRequestSynthesizesFallbackMessage() throws {
        let spool = tempSpoolURL(); defer { try? FileManager.default.removeItem(at: spool) }
        let stdin = #"{"session_id":"u1","hook_event_name":"PermissionRequest","model":"gpt-5-codex"}"#
        _ = ClaudegotchiHook.run(args: ["claudegotchi-hook", "codex_permission_request"], stdin: stdin, spoolURL: spool)
        let e = try firstEvent(spool)
        XCTAssertEqual(e.notificationType, "approval_request")
        XCTAssertEqual(e.message, "Codex 请求权限")
    }

    func testCodexStopReadsTokensFromRolloutLastTokenCount() throws {
        let spool = tempSpoolURL()
        let rollout = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rollout-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: spool); try? FileManager.default.removeItem(at: rollout) }
        let text = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":21889,"cached_input_tokens":21376,"output_tokens":22}}}}"#
        try text.write(to: rollout, atomically: true, encoding: .utf8)
        let stdin = #"{"session_id":"u1","transcript_path":"\#(rollout.path)","hook_event_name":"Stop","model":"gpt-5-codex"}"#
        _ = ClaudegotchiHook.run(args: ["claudegotchi-hook", "codex_stop"], stdin: stdin, spoolURL: spool)
        let e = try firstEvent(spool)
        XCTAssertEqual(e.type, .stop)
        XCTAssertEqual(e.tokensIn, 21889)
        XCTAssertEqual(e.tokensOut, 22)
        XCTAssertEqual(e.model, "gpt-5-codex")
        XCTAssertEqual(e.platform, "codex")
    }

    func testCodexUserPromptSubmitTruncatesPromptAndNamespaces() throws {
        let spool = tempSpoolURL(); defer { try? FileManager.default.removeItem(at: spool) }
        let prompt = String(repeating: "字", count: 200)
        let stdin = #"{"session_id":"u1","hook_event_name":"UserPromptSubmit","prompt":"\#(prompt)"}"#
        _ = ClaudegotchiHook.run(args: ["claudegotchi-hook", "codex_user_prompt_submit"], stdin: stdin, spoolURL: spool)
        let e = try firstEvent(spool)
        XCTAssertEqual(e.type, .userPromptSubmit)
        XCTAssertEqual(e.prompt?.count, 120)
        XCTAssertEqual(e.sessionId, "codex-u1")
        XCTAssertEqual(e.platform, "codex")
    }
}
