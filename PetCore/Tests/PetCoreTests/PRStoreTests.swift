import XCTest
import GRDB
@testable import PetCore

final class PRStoreTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "prstore-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func pr(_ slug: String, _ n: Int, decision: String? = nil, fetchedAt: Int64 = 1) -> PR {
        PR(
            id: nil, repoSlug: slug, number: n, title: "t#\(n)", author: "alice",
            state: "OPEN", isDraft: false, reviewDecision: decision, unresolvedCount: 0,
            lastApprovedReviewAt: 0, headBranch: "h", url: "u", updatedAt: 0,
            isMine: true, fetchedAt: fetchedAt
        )
    }

    func testUpsertInsertsThenUpdatesInPlace() throws {
        try PRStore.upsertPRs([pr("o/r", 1, decision: "REVIEW_REQUIRED")], in: db)
        try PRStore.upsertPRs([pr("o/r", 1, decision: "APPROVED", fetchedAt: 99)], in: db)
        let all = try PRStore.allPRs(in: db)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.reviewDecision, "APPROVED")
        XCTAssertEqual(all.first?.fetchedAt, 99)
    }

    func testAllPRsReturnsEveryRow() throws {
        try PRStore.upsertPRs([pr("o/r", 1), pr("o/r", 2), pr("o/s", 3)], in: db)
        XCTAssertEqual(try PRStore.allPRs(in: db).count, 3)
    }

    func testAddAndListWatchedReposAndAuthors() throws {
        let repo = try PRStore.addRepo(slug: "o/r", localPath: "/tmp/r", enabled: true, in: db)
        _ = try PRStore.addRepo(slug: "o/s", localPath: nil, enabled: false, in: db)
        try PRStore.addAuthor(repoId: repo.id!, login: "alice", in: db)
        try PRStore.addAuthor(repoId: repo.id!, login: "bob", in: db)

        XCTAssertEqual(try PRStore.watchedRepos(in: db).map(\.slug), ["o/r", "o/s"])
        XCTAssertEqual(try PRStore.authors(repoId: repo.id!, in: db).map(\.login), ["alice", "bob"])
    }

    func testRemoveRepoCascadesAuthors() throws {
        let repo = try PRStore.addRepo(slug: "o/r", localPath: nil, enabled: true, in: db)
        try PRStore.addAuthor(repoId: repo.id!, login: "alice", in: db)
        try PRStore.removeRepo(id: repo.id!, in: db)
        XCTAssertEqual(try PRStore.watchedRepos(in: db).count, 0)
        XCTAssertEqual(try PRStore.authors(repoId: repo.id!, in: db).count, 0)
    }

    func testRemoveAuthorDeletesOnlyThatLogin() throws {
        let repo = try PRStore.addRepo(slug: "o/r", localPath: nil, enabled: true, in: db)
        try PRStore.addAuthor(repoId: repo.id!, login: "alice", in: db)
        let bob = try PRStore.addAuthor(repoId: repo.id!, login: "bob", in: db)
        try PRStore.removeAuthor(id: bob.id!, in: db)
        XCTAssertEqual(try PRStore.authors(repoId: repo.id!, in: db).map(\.login), ["alice"])
    }
}
