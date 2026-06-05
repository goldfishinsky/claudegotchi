import XCTest
@testable import PetCore

final class SubprocessTests: XCTestCase {
    func testMergeToolPathPrependsHomebrewPreservesExistingDedupes() {
        let merged = SystemProcessRunner.mergeToolPath(into: "/custom/bin:/usr/bin")
        let dirs = merged.split(separator: ":").map(String.init)
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))            // Finder-launch fix
        XCTAssertTrue(dirs.contains("/custom/bin"))                  // existing PATH preserved
        XCTAssertLessThan(dirs.firstIndex(of: "/opt/homebrew/bin")!,
                          dirs.firstIndex(of: "/custom/bin")!)        // tool dirs win
        XCTAssertEqual(dirs.filter { $0 == "/usr/bin" }.count, 1)    // deduped
    }

    func testEnvironmentWithToolPathKeepsOtherVars() {
        let env = SystemProcessRunner.environmentWithToolPath()
        XCTAssertTrue((env["PATH"] ?? "").contains("/opt/homebrew/bin"))
        XCTAssertEqual(env["HOME"], ProcessInfo.processInfo.environment["HOME"])  // HOME (gh auth) preserved
    }

    func testSystemRunnerCapturesStdoutAndStatus() throws {
        let r = SystemProcessRunner()
        let result = try r.run("/bin/echo", ["hello"], cwd: nil, timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "hello\n")
    }

    func testSystemRunnerReturnsNonZeroStatusNotThrow() throws {
        let r = SystemProcessRunner()
        let result = try r.run("/bin/sh", ["-c", "exit 3"], cwd: nil, timeout: 5)
        XCTAssertEqual(result.status, 3)
    }

    func testFakeRunnerRecordsArgvAndReturnsScripted() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: Data("ok".utf8), stderr: "")]
        let result = try fake.run("gh", ["pr", "list"], cwd: nil, timeout: nil)
        XCTAssertEqual(result.stdout, Data("ok".utf8))
        XCTAssertEqual(fake.calls.first?.executable, "gh")
        XCTAssertEqual(fake.calls.first?.args, ["pr", "list"])
    }

    func testStreamingDeliversLinesIncrementallyBeforeExit() throws {
        let r = SystemProcessRunner()
        var lines: [String] = []
        let result = try r.runStreaming(
            "/bin/sh", ["-c", "echo a; echo b; echo c"],
            cwd: nil, timeout: 5, cancel: nil,
            onStdoutLine: { lines.append($0) }
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(lines, ["a", "b", "c"])
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "a\nb\nc\n")
    }

    func testStreamingDoesNotDeadlockOnLargeOutput() throws {
        // ~1MB, far over the ~64KB OS pipe buffer: a post-wait readDataToEndOfFile
        // deadlocks here (child blocks writing a full pipe, parent blocks waiting).
        let r = SystemProcessRunner()
        var byteCount = 0
        let result = try r.runStreaming(
            "/bin/sh", ["-c", "for i in $(seq 1 20000); do echo 0123456789012345678901234567890123456789012345678; done"],
            cwd: nil, timeout: 20, cancel: nil,
            onStdoutLine: { byteCount += $0.utf8.count }
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThan(byteCount, 900_000)
    }

    func testStreamingCancelTearsDownProcessGroupPromptly() throws {
        let r = SystemProcessRunner()
        let cancel = CancelToken()
        // Child forks a long-lived grandchild into the same group, then sleeps.
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancel.cancel() }
        let result = try r.runStreaming(
            "/bin/sh", ["-c", "sleep 60 & sleep 60"],
            cwd: nil, timeout: 30, cancel: cancel,
            onStdoutLine: { _ in }
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5, "cancel must tear the process group down promptly, not wait for sleep")
        XCTAssertNotEqual(result.status, 0, "a killed process reports non-zero/terminated status")
    }

    func testStreamingTimeoutKillsGroupAndThrows() throws {
        let r = SystemProcessRunner()
        let start = Date()
        XCTAssertThrowsError(
            try r.runStreaming(
                "/bin/sh", ["-c", "sleep 60 & sleep 60"],
                cwd: nil, timeout: 0.3, cancel: nil,
                onStdoutLine: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testFakeRunnerStreamsScriptedLinesAndHonorsCancel() throws {
        let fake = FakeProcessRunner()
        fake.streamLines = ["{\"a\":1}", "{\"b\":2}"]
        fake.results = [ProcessResult(status: 0, stdout: Data("{\"a\":1}\n{\"b\":2}\n".utf8), stderr: "")]
        var got: [String] = []
        let result = try fake.runStreaming("claude", ["-p", "x"], cwd: nil, timeout: nil,
                                           cancel: CancelToken(), onStdoutLine: { got.append($0) })
        XCTAssertEqual(got, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(fake.calls.first?.executable, "claude")
    }
}
