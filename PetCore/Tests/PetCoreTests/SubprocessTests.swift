import XCTest
@testable import PetCore

final class SubprocessTests: XCTestCase {
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
}
