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

    func testApprovalTransitionUpsertsApprovedAndEmitsEvent() {
        let old = [pr(slug: "o/r", number: 1, reviewDecision: "REVIEW_REQUIRED")]
        let fresh = [ClassifiedPR(slug: "o/r", list: ghPR(1, decision: "APPROVED"),
                                  detail: detail(1, decision: "APPROVED", approvedAtMs: 7000))]
        let result = PRSync.diff(old: old, fresh: fresh, disappeared: [],
                                 selfLogin: "alice", config: cfg, nowMs: 0)
        XCTAssertEqual(result.upserts[0].reviewDecision, "APPROVED")
        XCTAssertEqual(result.events.filter { $0.type == .prApproved }.count, 1)
        XCTAssertEqual(result.events.first?.eventId, "pr:o/r#1:approved:7000")
    }

    func testDisappearedMergedUpdatesStateAndEmitsEvent() {
        let old = [pr(slug: "o/r", number: 5, state: "OPEN")]
        let result = PRSync.diff(old: old, fresh: [], disappeared: [(slug: "o/r", number: 5, outcome: .merged(atMs: 9000))],
                                 selfLogin: "alice", config: cfg, nowMs: 0)
        XCTAssertEqual(result.upserts.count, 1)
        XCTAssertEqual(result.upserts[0].state, "MERGED")
        XCTAssertEqual(result.events.filter { $0.type == .prMerged }.count, 1)
        XCTAssertEqual(result.events.first?.eventId, "pr:o/r#5:merged:9000")
    }

    func testDisappearedClosedUpdatesStateOnly() {
        let old = [pr(slug: "o/r", number: 6, state: "OPEN")]
        let result = PRSync.diff(old: old, fresh: [], disappeared: [(slug: "o/r", number: 6, outcome: .closed)],
                                 selfLogin: "alice", config: cfg, nowMs: 0)
        XCTAssertEqual(result.upserts[0].state, "CLOSED")
        XCTAssertTrue(result.events.isEmpty)
    }

    func testWindowDropoutLeavesCacheUntouched() {
        let old = [pr(slug: "o/r", number: 7, state: "OPEN")]
        let result = PRSync.diff(old: old, fresh: [], disappeared: [(slug: "o/r", number: 7, outcome: .windowDropout)],
                                 selfLogin: "alice", config: cfg, nowMs: 0)
        XCTAssertTrue(result.upserts.isEmpty)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testApprovedTransitionEmitsOneEvent() {
        let old = [pr(slug: "o/r", number: 1, reviewDecision: "REVIEW_REQUIRED", lastApprovedReviewAt: 0)]
        let fresh = [classified(slug: "o/r", number: 1, reviewDecision: "APPROVED", lastApprovedReviewAtMs: 1700)]
        let r = PRSync.diff(old: old, fresh: fresh, disappeared: [],
                            selfLogin: "me", config: cfg, nowMs: 9999)
        let approved = r.events.filter { $0.type == .prApproved }
        XCTAssertEqual(approved.count, 1)
        XCTAssertEqual(approved.first?.eventId, "pr:o/r#1:approved:1700")
        XCTAssertEqual(approved.first?.ts, 1700)
    }

    func testColdStartAlreadyApprovedDoesNotRetroFire() {
        // First poll after adding a repo: old is empty, PR already APPROVED.
        // Must NOT emit (silent load, §10 first-poll); upsert still happens.
        let fresh = [classified(slug: "o/r", number: 1, reviewDecision: "APPROVED", lastApprovedReviewAtMs: 1700)]
        let r = PRSync.diff(old: [], fresh: fresh, disappeared: [],
                            selfLogin: "me", config: cfg, nowMs: 9999)
        XCTAssertTrue(r.events.isEmpty, "Cold-start already-approved PR does not retro-fire pr_approved")
        XCTAssertEqual(r.upserts.count, 1, "But the PR is still cached on first sight")
    }

    func testReApprovalEmitsNewDistinctEvent() {
        // old exists (CHANGES_REQUESTED) → re-approve at a LATER ts → new id.
        let old = [pr(slug: "o/r", number: 1, reviewDecision: "CHANGES_REQUESTED", lastApprovedReviewAt: 1700)]
        let fresh = [classified(slug: "o/r", number: 1, reviewDecision: "APPROVED", lastApprovedReviewAtMs: 2500)]
        let r = PRSync.diff(old: old, fresh: fresh, disappeared: [],
                            selfLogin: "me", config: cfg, nowMs: 9999)
        let approved = r.events.filter { $0.type == .prApproved }
        XCTAssertEqual(approved.count, 1)
        XCTAssertEqual(approved.first?.eventId, "pr:o/r#1:approved:2500",
                       "Re-approval at a new ts is a separately-applicable event")
    }

    func testStillApprovedNoNewEvent() {
        let old = [pr(slug: "o/r", number: 1, reviewDecision: "APPROVED", lastApprovedReviewAt: 1700)]
        let fresh = [classified(slug: "o/r", number: 1, reviewDecision: "APPROVED", lastApprovedReviewAtMs: 1700)]
        let r = PRSync.diff(old: old, fresh: fresh, disappeared: [],
                            selfLogin: "me", config: cfg, nowMs: 9999)
        XCTAssertTrue(r.events.isEmpty, "Unchanged APPROVED poll emits no event")
    }

    func testMergedDisappearanceEmitsMergedEvent() {
        let old = [pr(slug: "o/r", number: 7, reviewDecision: "APPROVED", lastApprovedReviewAt: 1700)]
        let r = PRSync.diff(old: old, fresh: [],
                            disappeared: [(slug: "o/r", number: 7, outcome: .merged(atMs: 3300))],
                            selfLogin: "me", config: cfg, nowMs: 9999)
        let merged = r.events.filter { $0.type == .prMerged }
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.eventId, "pr:o/r#7:merged:3300")
        XCTAssertEqual(merged.first?.ts, 3300)
    }

    func testClosedAndWindowDropoutEmitNoEvent() {
        let old = [pr(slug: "o/r", number: 8, reviewDecision: "REVIEW_REQUIRED", lastApprovedReviewAt: 0),
                   pr(slug: "o/r", number: 9, reviewDecision: "REVIEW_REQUIRED", lastApprovedReviewAt: 0)]
        let r = PRSync.diff(old: old, fresh: [],
                            disappeared: [(slug: "o/r", number: 8, outcome: .closed),
                                          (slug: "o/r", number: 9, outcome: .windowDropout)],
                            selfLogin: "me", config: cfg, nowMs: 9999)
        XCTAssertTrue(r.events.isEmpty)
    }

    func testCrossRepoSamePrNumberDoesNotCollideOrCrossSlug() {
        // Two repos each with PR #1: approval transition in repo-a, merge in repo-b.
        // (slug, number) keying must keep slugs straight; ids must not collide.
        let old = [pr(slug: "o/a", number: 1, reviewDecision: "REVIEW_REQUIRED", lastApprovedReviewAt: 0),
                   pr(slug: "o/b", number: 1, reviewDecision: "APPROVED", lastApprovedReviewAt: 50)]
        let fresh = [classified(slug: "o/a", number: 1, reviewDecision: "APPROVED", lastApprovedReviewAtMs: 100)]
        let r = PRSync.diff(old: old, fresh: fresh,
                            disappeared: [(slug: "o/b", number: 1, outcome: .merged(atMs: 200))],
                            selfLogin: "me", config: cfg, nowMs: 9999)
        let ids = Set(r.events.map { $0.eventId })
        XCTAssertTrue(ids.contains("pr:o/a#1:approved:100"))
        XCTAssertTrue(ids.contains("pr:o/b#1:merged:200"))
        XCTAssertEqual(ids.count, 2, "Same PR number in two repos never collides or cross-slugs")
    }

    func testDistinctTransitionTsIdsNeverCollide() {
        let old = [pr(slug: "o/r", number: 1, reviewDecision: "REVIEW_REQUIRED", lastApprovedReviewAt: 0),
                   pr(slug: "o/r", number: 2, reviewDecision: "REVIEW_REQUIRED", lastApprovedReviewAt: 0)]
        let fresh = [classified(slug: "o/r", number: 1, reviewDecision: "APPROVED", lastApprovedReviewAtMs: 100),
                     classified(slug: "o/r", number: 2, reviewDecision: "APPROVED", lastApprovedReviewAtMs: 100)]
        let r = PRSync.diff(old: old, fresh: fresh,
                            disappeared: [(slug: "o/r", number: 2, outcome: .merged(atMs: 100))],
                            selfLogin: "me", config: cfg, nowMs: 9999)
        let ids = Set(r.events.map { $0.eventId })
        XCTAssertEqual(ids.count, r.events.count, "(slug,number,transition,ts) ids never collide")
    }
}
