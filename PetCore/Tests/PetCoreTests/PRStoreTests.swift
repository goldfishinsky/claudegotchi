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
}
