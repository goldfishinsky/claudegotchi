import XCTest
@testable import PetCore

final class WorkPressureTests: XCTestCase {
    let cfg = ConfigYAML.defaults

    private func pr(isMine: Bool = true, state: String = "OPEN", isDraft: Bool = false,
                    reviewDecision: String? = nil, unresolved: Int = 0, number: Int) -> PR {
        PR(id: nil, repoSlug: "o/r", number: number, title: "t", author: "me",
           state: state, isDraft: isDraft, reviewDecision: reviewDecision,
           unresolvedCount: unresolved, lastApprovedReviewAt: 0,
           headBranch: "feat", url: "https://x", updatedAt: 0, isMine: isMine, fetchedAt: 0)
    }

    func testPendingCountCountsChangesRequestedAndUnresolved() {
        let prs = [
            pr(reviewDecision: "CHANGES_REQUESTED", number: 1),
            pr(unresolved: 2, number: 2),
            pr(reviewDecision: "APPROVED", number: 3)
        ]
        XCTAssertEqual(WorkPressure.pendingCount(prs), 2)
    }

    func testPendingCountExcludesDraftsAndNonMineAndNonOpen() {
        let prs = [
            pr(isMine: false, reviewDecision: "CHANGES_REQUESTED", number: 1),
            pr(isDraft: true, reviewDecision: "CHANGES_REQUESTED", number: 2),
            pr(state: "MERGED", reviewDecision: "CHANGES_REQUESTED", number: 3),
            pr(reviewDecision: "CHANGES_REQUESTED", number: 4)
        ]
        XCTAssertEqual(WorkPressure.pendingCount(prs), 1)
    }

    func testTierThresholds() {
        XCTAssertEqual(WorkPressure.tier([], config: cfg), .calm)
        let one = [pr(reviewDecision: "CHANGES_REQUESTED", number: 1)]
        XCTAssertEqual(WorkPressure.tier(one, config: cfg), .busy)
        let three = (1...3).map { pr(reviewDecision: "CHANGES_REQUESTED", number: $0) }
        XCTAssertEqual(WorkPressure.tier(three, config: cfg), .stressed)
    }
}
