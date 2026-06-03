import Foundation

public struct ClassifiedPR: Equatable {
    public let slug: String
    public let list: GHPullRequest
    public let detail: PRDetail
    public init(slug: String, list: GHPullRequest, detail: PRDetail) {
        self.slug = slug
        self.list = list
        self.detail = detail
    }
}

public struct SyncResult: Equatable {
    public let upserts: [PR]
    public let events: [Event]
    public init(upserts: [PR], events: [Event]) {
        self.upserts = upserts
        self.events = events
    }
}

public enum PRSync {
    public static func diff(
        old: [PR], fresh: [ClassifiedPR], disappeared: [(slug: String, number: Int, outcome: PRDisappearance)],
        selfLogin: String, config: ConfigYAML, nowMs: Int64
    ) -> SyncResult {
        var upserts: [PR] = []

        for c in fresh {
            let priorState = old.first { $0.repoSlug == c.slug && $0.number == c.list.number }?.state
            let state = stateFrom(detail: c.detail, fallback: priorState ?? "OPEN")
            upserts.append(PR(
                id: nil,
                repoSlug: c.slug,
                number: c.list.number,
                title: c.list.title,
                author: c.list.author,
                state: state,
                isDraft: c.list.isDraft,
                reviewDecision: c.detail.reviewDecision ?? c.list.reviewDecision,
                unresolvedCount: c.detail.unresolvedCount,
                lastApprovedReviewAt: c.detail.lastApprovedReviewAtMs,
                headBranch: c.list.headBranch,
                url: c.list.url,
                updatedAt: c.list.updatedAtMs,
                isMine: c.list.author == selfLogin,
                fetchedAt: nowMs
            ))
        }

        for (slug, number, outcome) in disappeared {
            guard var row = old.first(where: { $0.repoSlug == slug && $0.number == number }) else { continue }
            switch outcome {
            case .merged(let atMs):
                row.state = "MERGED"
                row.lastApprovedReviewAt = max(row.lastApprovedReviewAt, atMs)
            case .closed:
                row.state = "CLOSED"
            case .windowDropout:
                continue
            }
            row.fetchedAt = nowMs
            upserts.append(row)
        }

        var events: [Event] = []

        let oldByKey = Dictionary(
            old.map { ($0.repoSlug + "#" + String($0.number), $0) },
            uniquingKeysWith: { a, _ in a }
        )

        for c in fresh {
            let number = c.list.number
            let key = c.slug + "#" + String(number)
            guard let prior = oldByKey[key] else { continue }   // cold-start: first sight never retro-fires
            let wasApproved = prior.reviewDecision == "APPROVED"
            let isApproved = c.detail.reviewDecision == "APPROVED"
            if isApproved && !wasApproved {
                let ms = c.detail.lastApprovedReviewAtMs
                events.append(Event(
                    schemaVersion: 1,
                    eventId: "pr:\(c.slug)#\(number):approved:\(ms)",
                    ts: ms, type: .prApproved,
                    sessionId: nil, tool: nil, tokensIn: nil, tokensOut: nil, model: nil, cwd: nil
                ))
            }
        }

        for (slug, number, outcome) in disappeared {
            guard case let .merged(atMs) = outcome else { continue }
            events.append(Event(
                schemaVersion: 1,
                eventId: "pr:\(slug)#\(number):merged:\(atMs)",
                ts: atMs, type: .prMerged,
                sessionId: nil, tool: nil, tokensIn: nil, tokensOut: nil, model: nil, cwd: nil
            ))
        }

        return SyncResult(upserts: upserts, events: events)
    }

    private static func stateFrom(detail: PRDetail, fallback: String) -> String {
        switch detail.state.uppercased() {
        case "OPEN", "CLOSED", "MERGED": return detail.state.uppercased()
        default: return fallback
        }
    }
}
