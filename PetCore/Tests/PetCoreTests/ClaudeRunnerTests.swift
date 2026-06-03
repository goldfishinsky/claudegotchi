import XCTest
@testable import PetCore

final class ClaudeRunnerTests: XCTestCase {
    func testFixArgvContainsScopedFlags() {
        let args = CLIClaudeRunner.fixArgs(
            prompt: "address feedback",
            allowedTools: "Edit,Read", disallowedTools: "WebFetch",
            permissionMode: "acceptEdits"
        )
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(args[1], "address feedback")
        XCTAssertTrue(args.contains("--permission-mode"))
        XCTAssertTrue(args.contains("acceptEdits"))
        XCTAssertTrue(args.contains("--allowedTools"))
        XCTAssertTrue(args.contains("Edit,Read"))
        XCTAssertTrue(args.contains("--disallowedTools"))
        XCTAssertTrue(args.contains("WebFetch"))
        XCTAssertTrue(args.contains("--output-format"))
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertTrue(args.contains("--verbose"))
    }

    func testParseProgressExtractsToolFromAssistantToolUse() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}],"usage":{"input_tokens":1200,"output_tokens":300}}}
        """#
        let p = CLIClaudeRunner.parseProgress(line)
        XCTAssertEqual(p?.tool, "Edit")
        XCTAssertEqual(p?.tokens, 1500)
    }

    func testParseProgressIgnoresNonJSONLine() {
        XCTAssertNil(CLIClaudeRunner.parseProgress("not json"))
        XCTAssertNil(CLIClaudeRunner.parseProgress(""))
    }

    func testParseProgressResultLineHasNilTool() {
        let line = #"{"type":"result","subtype":"success","usage":{"input_tokens":10,"output_tokens":5}}"#
        let p = CLIClaudeRunner.parseProgress(line)
        XCTAssertNil(p?.tool)
        XCTAssertEqual(p?.tokens, 15)
    }

    func testCancelTokenFlips() {
        let t = CancelToken()
        XCTAssertFalse(t.isCancelled)
        t.cancel()
        XCTAssertTrue(t.isCancelled)
    }

    func testRunFixSpawnsClaudeAndReturnsExit() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: Data(), stderr: "")]
        let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: log) }
        let exit = try CLIClaudeRunner(runner: fake).runFix(
            prompt: "p", cwd: URL(fileURLWithPath: "/wt"),
            allowedTools: "Edit", disallowedTools: "WebFetch",
            permissionMode: "acceptEdits", timeout: 5, logURL: log,
            onProgress: { _ in }, cancel: CancelToken()
        )
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(fake.calls.first?.executable, "claude")
        XCTAssertEqual(fake.calls.first?.cwd, URL(fileURLWithPath: "/wt"))
    }
}
