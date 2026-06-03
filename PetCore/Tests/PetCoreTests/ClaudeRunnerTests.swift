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

    func testRunFixStreamsProgressLiveMoreThanOnce() throws {
        let fake = FakeProcessRunner()
        fake.streamLines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}"#,
            #"{"type":"result","subtype":"success","usage":{"input_tokens":10,"output_tokens":5}}"#,
        ]
        fake.results = [ProcessResult(status: 0, stdout: Data(), stderr: "")]
        let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: log) }
        var progress: [ClaudeProgress] = []
        let exit = try CLIClaudeRunner(runner: fake).runFix(
            prompt: "p", cwd: URL(fileURLWithPath: "/wt"),
            allowedTools: "Edit", disallowedTools: "WebFetch",
            permissionMode: "acceptEdits", timeout: 5, logURL: log,
            onProgress: { progress.append($0) }, cancel: CancelToken()
        )
        XCTAssertEqual(exit, 0)
        XCTAssertGreaterThan(progress.count, 1, "progress must arrive per-line, not in one burst")
        XCTAssertEqual(progress.first?.tool, "Read")
        XCTAssertEqual(progress.dropFirst().first?.tool, "Edit")
    }

    func testRunFixWritesRedactedLogIncrementally() throws {
        let fake = FakeProcessRunner()
        fake.streamLines = [
            #"{"token":"ghp_0123456789abcdefghijklmnopqrstuvwxyz","type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#,
        ]
        fake.results = [ProcessResult(status: 0, stdout: Data(), stderr: "")]
        let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: log) }
        _ = try CLIClaudeRunner(runner: fake).runFix(
            prompt: "p", cwd: URL(fileURLWithPath: "/wt"),
            allowedTools: "Edit", disallowedTools: "WebFetch",
            permissionMode: "acceptEdits", timeout: 5, logURL: log,
            onProgress: { _ in }, cancel: CancelToken()
        )
        let contents = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(contents.contains("ghp_0123456789"), "secrets must be redacted in the log")
        XCTAssertTrue(contents.contains("REDACTED") || contents.contains("tool_use"))
    }

    func testRunFixPassesCancelTokenThroughToRunner() throws {
        let fake = FakeProcessRunner()
        fake.blockUntilCancelled = true
        let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: log) }
        let cancel = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancel.cancel() }
        let start = Date()
        let exit = try CLIClaudeRunner(runner: fake).runFix(
            prompt: "p", cwd: URL(fileURLWithPath: "/wt"),
            allowedTools: "Edit", disallowedTools: "WebFetch",
            permissionMode: "acceptEdits", timeout: 30, logURL: log,
            onProgress: { _ in }, cancel: cancel
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "cancel must reach the runner and stop the run")
        XCTAssertNotEqual(exit, 0)
    }
}
