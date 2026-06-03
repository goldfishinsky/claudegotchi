import XCTest
@testable import PetCore

final class GitHubClientTests: XCTestCase {
    private func bytes(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/gh/\(name)", withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func testListDecodesAndParsesTimestamp() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: try bytes("pr-list"), stderr: "")]
        let client = GHCLIClient(runner: fake)
        let prs = try client.listOpenPRs(slug: "jalen/app", author: "jalen")
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs[0].number, 128)
        XCTAssertEqual(prs[0].author, "jalen")
        XCTAssertEqual(prs[0].reviewDecision, "CHANGES_REQUESTED")
        XCTAssertEqual(prs[0].headBranch, "fix/login-race")
        XCTAssertEqual(prs[0].updatedAtMs, 1_780_392_600_000) // 2026-06-02T09:30:00Z
        XCTAssertTrue(prs[1].isDraft)
        XCTAssertNil(prs[1].reviewDecision)
    }

    func testListBuildsArgvNeverShell() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: try bytes("pr-list"), stderr: "")]
        _ = try GHCLIClient(runner: fake).listOpenPRs(slug: "jalen/app", author: "jalen")
        let call = fake.calls.first!
        XCTAssertEqual(call.executable, "gh")
        XCTAssertEqual(Array(call.args.prefix(2)), ["pr", "list"])
        XCTAssertTrue(call.args.contains("--repo"))
        XCTAssertTrue(call.args.contains("jalen/app"))
        XCTAssertTrue(call.args.contains("--author"))
        XCTAssertTrue(call.args.contains("jalen"))
        XCTAssertFalse(call.args.contains("/bin/sh"))
    }

    func testDetailComputesUnresolvedAndApprovalTs() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: try bytes("pr-detail-approved"), stderr: "")]
        let detail = try GHCLIClient(runner: fake).prDetail(slug: "jalen/app", number: 128)
        XCTAssertEqual(detail.reviewDecision, "APPROVED")
        XCTAssertEqual(detail.unresolvedCount, 1)
        XCTAssertEqual(detail.lastApprovedReviewAtMs, 1_780_395_300_000) // 2026-06-02T10:15:00Z
        XCTAssertEqual(detail.threads.filter { !$0.isResolved }.first?.path, "src/auth.ts")
    }

    func testClassifyMerged() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: try bytes("pr-view-merged"), stderr: "")]
        let d = try GHCLIClient(runner: fake).classifyDisappeared(slug: "jalen/app", number: 128)
        XCTAssertEqual(d, .merged(atMs: 1_780_398_000_000)) // 2026-06-02T11:00:00Z
    }

    func testClassifyClosed() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: try bytes("pr-view-closed"), stderr: "")]
        let d = try GHCLIClient(runner: fake).classifyDisappeared(slug: "jalen/app", number: 128)
        XCTAssertEqual(d, .closed)
    }

    func testClassifyWindowDropoutOnNonZeroExit() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 1, stdout: Data(), stderr: "no PRs found")]
        let d = try GHCLIClient(runner: fake).classifyDisappeared(slug: "jalen/app", number: 999)
        XCTAssertEqual(d, .windowDropout)
    }

    func testSelfLoginTrimsOutput() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: Data("jalen\n".utf8), stderr: "")]
        XCTAssertEqual(try GHCLIClient(runner: fake).selfLogin(), "jalen")
    }
}
