import XCTest
@testable import PetCore

final class SessionRepoTests: XCTestCase {
    func testPlainRepoIsBasename() {
        XCTAssertEqual(SessionRepo.labels(cwds: ["/Users/jalen/code/claudegotchi"]), ["claudegotchi"])
    }

    func testTrailingSlashTrimmed() {
        XCTAssertEqual(SessionRepo.labels(cwds: ["/Users/jalen/code/phoenix/"]), ["phoenix"])
    }

    func testUnknownCwd() {
        XCTAssertEqual(SessionRepo.labels(cwds: [nil]), ["未知目录"])
        XCTAssertEqual(SessionRepo.labels(cwds: [""]), ["未知目录"])
    }

    func testWorktreeShowsRepoAndName() {
        let cwd = "/Users/jalen/code/phoenix/.claude/worktrees/feature-x"
        XCTAssertEqual(SessionRepo.labels(cwds: [cwd]), ["phoenix ⌥ feature-x"])
    }

    func testWorktreeDerivesRepoFromSegmentBeforeDotClaude() {
        let cwd = "/work/daoai/phoenix/.claude/worktrees/wt-up/nested/dir"
        let p = SessionRepo.parse(cwd: cwd)
        XCTAssertEqual(p.repo, "phoenix")
        XCTAssertEqual(p.worktree, "wt-up", "only the first segment after the marker is the worktree")
    }

    func testTwoWorktreesOfSameRepoDoNotCollide() {
        let a = "/Users/jalen/code/phoenix/.claude/worktrees/feat-a"
        let b = "/Users/jalen/code/phoenix/.claude/worktrees/feat-b"
        XCTAssertEqual(SessionRepo.labels(cwds: [a, b]),
                       ["phoenix ⌥ feat-a", "phoenix ⌥ feat-b"],
                       "same repo path → distinguished by worktree, not parent prefix")
    }

    func testBasenameCollisionDisambiguatesWithParent() {
        let a = "/Users/jalen/daoai/phoenix"
        let b = "/Users/jalen/code/phoenix"
        XCTAssertEqual(SessionRepo.labels(cwds: [a, b]), ["daoai/phoenix", "code/phoenix"])
    }

    func testNoCollisionWhenBasenamesDiffer() {
        let a = "/Users/jalen/daoai/phoenix"
        let b = "/Users/jalen/code/claudegotchi"
        XCTAssertEqual(SessionRepo.labels(cwds: [a, b]), ["phoenix", "claudegotchi"])
    }

    func testWorktreeCollidesWithPlainRepoOfSameName() {
        let wt = "/Users/jalen/daoai/phoenix/.claude/worktrees/feat"
        let plain = "/Users/jalen/code/phoenix"
        XCTAssertEqual(SessionRepo.labels(cwds: [wt, plain]),
                       ["daoai/phoenix ⌥ feat", "code/phoenix"])
    }
}
