import XCTest
@testable import PetCore

final class GitRunnerTests: XCTestCase {
    private let prefix = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]

    func testFetchArgvCarriesHardeningPrefixAndDashDash() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: Data(), stderr: "")]
        try CLIGitRunner(runner: fake).fetch(URL(fileURLWithPath: "/repo"), branch: "fix/login-race")
        let call = fake.calls.first!
        XCTAssertEqual(call.executable, "git")
        XCTAssertEqual(Array(call.args.prefix(4)), prefix)
        XCTAssertTrue(call.args.contains("fetch"))
        let dashDash = call.args.firstIndex(of: "--")!
        XCTAssertEqual(call.args[dashDash + 1], "fix/login-race")
    }

    func testAddWorktreeUsesDashBAndDashDash() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: Data(), stderr: "")]
        try CLIGitRunner(runner: fake).addWorktree(
            URL(fileURLWithPath: "/repo"),
            branch: "claudegotchi/fix/128",
            dir: URL(fileURLWithPath: "/wt/128"),
            startPoint: "origin/fix/login-race"
        )
        let args = fake.calls.first!.args
        XCTAssertEqual(Array(args.prefix(4)), prefix)
        XCTAssertTrue(args.contains("worktree"))
        XCTAssertTrue(args.contains("add"))
        let b = args.firstIndex(of: "-B")!
        XCTAssertEqual(args[b + 1], "claudegotchi/fix/128")
    }

    func testRemoveWorktreeForcesAndPrunes() throws {
        let fake = FakeProcessRunner()
        fake.results = [
            ProcessResult(status: 0, stdout: Data(), stderr: ""),
            ProcessResult(status: 0, stdout: Data(), stderr: ""),
        ]
        try CLIGitRunner(runner: fake).removeWorktree(
            URL(fileURLWithPath: "/repo"), dir: URL(fileURLWithPath: "/wt/128"))
        XCTAssertTrue(fake.calls[0].args.contains("remove"))
        XCTAssertTrue(fake.calls[0].args.contains("--force"))
        XCTAssertTrue(fake.calls[1].args.contains("prune"))
        XCTAssertEqual(Array(fake.calls[1].args.prefix(4)), prefix)
    }

    func testRemoteSlugParsesGitURL() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: Data("git@github.com:jalen/app.git\n".utf8), stderr: "")]
        let slug = try CLIGitRunner(runner: fake).remoteSlug(URL(fileURLWithPath: "/repo"))
        XCTAssertEqual(slug, "jalen/app")
    }

    func testRemoteSlugParsesHTTPSURL() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: Data("https://github.com/jalen/app.git\n".utf8), stderr: "")]
        XCTAssertEqual(try CLIGitRunner(runner: fake).remoteSlug(URL(fileURLWithPath: "/repo")), "jalen/app")
    }

    func testIsCleanReadsPorcelain() throws {
        let fake = FakeProcessRunner()
        fake.results = [ProcessResult(status: 0, stdout: Data(), stderr: "")]
        XCTAssertTrue(try CLIGitRunner(runner: fake).isClean(URL(fileURLWithPath: "/wt")))
        let dirty = FakeProcessRunner()
        dirty.results = [ProcessResult(status: 0, stdout: Data(" M a.txt\n".utf8), stderr: "")]
        XCTAssertFalse(try CLIGitRunner(runner: dirty).isClean(URL(fileURLWithPath: "/wt")))
    }

    func testCommitAllReturnsSha() throws {
        let fake = FakeProcessRunner()
        fake.results = [
            ProcessResult(status: 0, stdout: Data(), stderr: ""),                    // add -A
            ProcessResult(status: 0, stdout: Data(), stderr: ""),                    // commit
            ProcessResult(status: 0, stdout: Data("abc123def\n".utf8), stderr: ""),  // rev-parse HEAD
        ]
        let sha = try CLIGitRunner(runner: fake).commitAll(URL(fileURLWithPath: "/wt"), message: "claudegotchi fix")
        XCTAssertEqual(sha, "abc123def")
        XCTAssertEqual(Array(fake.calls[1].args.prefix(4)), prefix)
    }

    func testWorktreeListParsesPorcelainDirs() throws {
        let fake = FakeProcessRunner()
        let porcelain = "worktree /repo\nHEAD a\nbranch refs/heads/main\n\nworktree /wt/128\nHEAD b\n"
        fake.results = [ProcessResult(status: 0, stdout: Data(porcelain.utf8), stderr: "")]
        let dirs = try CLIGitRunner(runner: fake).worktreeList(URL(fileURLWithPath: "/repo"))
        XCTAssertEqual(dirs, ["/repo", "/wt/128"])
    }
}
