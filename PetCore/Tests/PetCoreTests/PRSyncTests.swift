import XCTest
@testable import PetCore

final class PRSyncTests: XCTestCase {
    let cfg = ConfigYAML.defaults

    private func ghPR(_ n: Int, author: String = "alice", decision: String? = nil,
                      draft: Bool = false, updatedAtMs: Int64 = 1000) -> GHPullRequest {
        GHPullRequest(
            number: n, title: "t#\(n)", author: author, isDraft: draft,
            reviewDecision: decision, headBranch: "h\(n)", url: "https://x/\(n)",
            updatedAtMs: updatedAtMs
        )
    }

    private func detail(_ n: Int, decision: String? = nil, unresolved: Int = 0,
                        state: String = "OPEN", approvedAtMs: Int64 = 0) -> PRDetail {
        PRDetail(
            number: n, reviewDecision: decision, unresolvedCount: unresolved,
            lastApprovedReviewAtMs: approvedAtMs, state: state, mergedAtMs: nil, threads: []
        )
    }

    private func pr(slug: String, number: Int, reviewDecision: String? = nil,
                    lastApprovedReviewAt: Int64 = 0, unresolved: Int = 0,
                    state: String = "OPEN") -> PR {
        PR(id: nil, repoSlug: slug, number: number, title: "t#\(number)", author: "alice",
           state: state, isDraft: false, reviewDecision: reviewDecision, unresolvedCount: unresolved,
           lastApprovedReviewAt: lastApprovedReviewAt, headBranch: "h\(number)", url: "https://x/\(number)",
           updatedAt: 0, isMine: true, fetchedAt: 0)
    }

    private func classified(slug: String, number: Int, reviewDecision: String? = nil,
                            lastApprovedReviewAtMs: Int64 = 0, unresolved: Int = 0,
                            author: String = "alice", draft: Bool = false,
                            state: String = "OPEN") -> ClassifiedPR {
        ClassifiedPR(
            slug: slug,
            list: GHPullRequest(
                number: number, title: "t#\(number)", author: author, isDraft: draft,
                reviewDecision: reviewDecision, headBranch: "h\(number)", url: "https://x/\(number)",
                updatedAtMs: 1000
            ),
            detail: PRDetail(
                number: number, reviewDecision: reviewDecision, unresolvedCount: unresolved,
                lastApprovedReviewAtMs: lastApprovedReviewAtMs, state: state, mergedAtMs: nil, threads: []
            )
        )
    }

    func testNewPRProducesUpsertNoEvents() {
        let fresh = [ClassifiedPR(slug: "o/r", list: ghPR(1, decision: "REVIEW_REQUIRED"),
                                  detail: detail(1, decision: "REVIEW_REQUIRED"))]
        let result = PRSync.diff(old: [], fresh: fresh, disappeared: [],
                                 selfLogin: "alice", config: cfg, nowMs: 5000)
        XCTAssertEqual(result.upserts.count, 1)
        XCTAssertEqual(result.upserts[0].number, 1)
        XCTAssertEqual(result.upserts[0].repoSlug, "o/r")
        XCTAssertEqual(result.upserts[0].reviewDecision, "REVIEW_REQUIRED")
        XCTAssertEqual(result.upserts[0].state, "OPEN")
        XCTAssertEqual(result.upserts[0].fetchedAt, 5000)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testTwoReposFirstSeenGetDistinctSlugRows() {
        let fresh = [ClassifiedPR(slug: "o/a", list: ghPR(1), detail: detail(1)),
                     ClassifiedPR(slug: "o/b", list: ghPR(1), detail: detail(1))]
        let result = PRSync.diff(old: [], fresh: fresh, disappeared: [],
                                 selfLogin: "alice", config: cfg, nowMs: 0)
        let keys = Set(result.upserts.map { "\($0.repoSlug)#\($0.number)" })
        XCTAssertEqual(keys, ["o/a#1", "o/b#1"])
        XCTAssertFalse(result.upserts.contains { $0.repoSlug.isEmpty })
    }

    func testIsMineComputedFromSelfLogin() {
        let mine = PRSync.diff(old: [], fresh: [ClassifiedPR(slug: "o/r", list: ghPR(1, author: "alice"), detail: detail(1))],
                               disappeared: [], selfLogin: "alice", config: cfg, nowMs: 0)
        XCTAssertTrue(mine.upserts[0].isMine)
        let theirs = PRSync.diff(old: [], fresh: [ClassifiedPR(slug: "o/r", list: ghPR(2, author: "bob"), detail: detail(2))],
                                 disappeared: [], selfLogin: "alice", config: cfg, nowMs: 0)
        XCTAssertFalse(theirs.upserts[0].isMine)
    }

    func testUpdatedPRMapsUnresolvedAndDecisionNoEvents() {
        let old = [pr(slug: "o/r", number: 1, reviewDecision: "REVIEW_REQUIRED", unresolved: 0)]
        let fresh = [ClassifiedPR(slug: "o/r", list: ghPR(1, decision: "CHANGES_REQUESTED"),
                                  detail: detail(1, decision: "CHANGES_REQUESTED", unresolved: 3))]
        let result = PRSync.diff(old: old, fresh: fresh, disappeared: [],
                                 selfLogin: "alice", config: cfg, nowMs: 0)
        XCTAssertEqual(result.upserts[0].reviewDecision, "CHANGES_REQUESTED")
        XCTAssertEqual(result.upserts[0].unresolvedCount, 3)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testApprovalTransitionStillEmitsNoEventsInP1() {
        let old = [pr(slug: "o/r", number: 1, reviewDecision: "REVIEW_REQUIRED")]
        let fresh = [ClassifiedPR(slug: "o/r", list: ghPR(1, decision: "APPROVED"),
                                  detail: detail(1, decision: "APPROVED", approvedAtMs: 7000))]
        let result = PRSync.diff(old: old, fresh: fresh, disappeared: [],
                                 selfLogin: "alice", config: cfg, nowMs: 0)
        XCTAssertEqual(result.upserts[0].reviewDecision, "APPROVED")
        XCTAssertTrue(result.events.isEmpty)
    }
}
