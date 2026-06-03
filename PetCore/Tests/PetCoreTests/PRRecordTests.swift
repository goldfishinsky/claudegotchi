import XCTest
import GRDB
@testable import PetCore

final class PRRecordTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "pr-record-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testPRRoundTrips() throws {
        let pr = PR(
            id: nil, repoSlug: "owner/name", number: 42, title: "fix: login race",
            author: "alice", state: "OPEN", isDraft: false,
            reviewDecision: "CHANGES_REQUESTED", unresolvedCount: 3,
            lastApprovedReviewAt: 0, headBranch: "fix-login", url: "https://x/42",
            updatedAt: 1_700_000_000_000, isMine: true, fetchedAt: 1_700_000_100_000
        )
        try db.write { var p = pr; try p.insert($0) }
        let fetched = try db.read { try PR.fetchOne($0, key: ["repo_slug": "owner/name", "number": 42]) }!
        XCTAssertEqual(fetched.repoSlug, "owner/name")
        XCTAssertEqual(fetched.number, 42)
        XCTAssertEqual(fetched.reviewDecision, "CHANGES_REQUESTED")
        XCTAssertEqual(fetched.unresolvedCount, 3)
        XCTAssertTrue(fetched.isDraft == false)
        XCTAssertTrue(fetched.isMine)
    }

    func testWatchedRepoAndAuthorRoundTrip() throws {
        try db.write { conn in
            var repo = WatchedRepo(id: nil, slug: "owner/name", localPath: "/tmp/clone", enabled: true)
            try repo.insert(conn)
            var author = WatchedAuthor(id: nil, repoId: repo.id!, login: "alice")
            try author.insert(conn)
        }
        let repo = try db.read { try WatchedRepo.fetchOne($0, key: ["slug": "owner/name"]) }!
        XCTAssertEqual(repo.localPath, "/tmp/clone")
        XCTAssertTrue(repo.enabled)
        let authors = try db.read { try WatchedAuthor.fetchAll($0) }
        XCTAssertEqual(authors.map(\.login), ["alice"])
    }
}
