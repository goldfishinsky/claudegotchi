import Foundation

public struct GHPullRequest: Equatable {
    public let number: Int
    public let title: String
    public let author: String
    public let isDraft: Bool
    public let reviewDecision: String?
    public let headBranch: String
    public let url: String
    public let updatedAtMs: Int64
}

public struct GHReviewThread: Equatable {
    public let path: String
    public let line: Int?
    public let author: String
    public let body: String
    public let isResolved: Bool
}

public struct PRDetail: Equatable {
    public let number: Int
    public let reviewDecision: String?
    public let unresolvedCount: Int
    public let lastApprovedReviewAtMs: Int64
    public let state: String
    public let mergedAtMs: Int64?
    public let threads: [GHReviewThread]
}

public enum PRDisappearance: Equatable {
    case merged(atMs: Int64)
    case closed
    case windowDropout
}

public protocol GitHubClient {
    func selfLogin() throws -> String
    func listOpenPRs(slug: String, author: String) throws -> [GHPullRequest]
    func prDetail(slug: String, number: Int) throws -> PRDetail
    func classifyDisappeared(slug: String, number: Int) throws -> PRDisappearance
}

public enum GitHubClientError: Error, Equatable {
    case commandFailed(status: Int32, stderr: String)
    case decodeFailed
}

public final class GHCLIClient: GitHubClient {
    private let runner: ProcessRunner
    public init(runner: ProcessRunner) { self.runner = runner }

    public func selfLogin() throws -> String {
        let r = try runner.run("gh", ["api", "user", "--jq", ".login"], cwd: nil, timeout: 30)
        guard r.status == 0 else {
            throw GitHubClientError.commandFailed(status: r.status, stderr: r.stderr)
        }
        return (String(data: r.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func listOpenPRs(slug: String, author: String) throws -> [GHPullRequest] {
        let r = try runner.run("gh", [
            "pr", "list", "--repo", slug, "--author", author, "--state", "open",
            "--json", "number,title,author,isDraft,reviewDecision,headRefName,url,updatedAt",
            "--limit", "50",
        ], cwd: nil, timeout: 60)
        guard r.status == 0 else {
            throw GitHubClientError.commandFailed(status: r.status, stderr: r.stderr)
        }
        let raw = try decode([RawListPR].self, r.stdout)
        return raw.map {
            GHPullRequest(
                number: $0.number, title: $0.title, author: $0.author.login,
                isDraft: $0.isDraft, reviewDecision: $0.reviewDecision,
                headBranch: $0.headRefName, url: $0.url,
                updatedAtMs: Self.rfc3339ms($0.updatedAt) ?? 0
            )
        }
    }

    public func prDetail(slug: String, number: Int) throws -> PRDetail {
        let r = try runner.run("gh", [
            "pr", "view", String(number), "--repo", slug,
            "--json", "number,reviewDecision,latestReviews,reviewThreads,state,mergedAt,url",
        ], cwd: nil, timeout: 60)
        guard r.status == 0 else {
            throw GitHubClientError.commandFailed(status: r.status, stderr: r.stderr)
        }
        return Self.detail(from: try decode(RawView.self, r.stdout))
    }

    public func classifyDisappeared(slug: String, number: Int) throws -> PRDisappearance {
        let r = try runner.run("gh", [
            "pr", "view", String(number), "--repo", slug,
            "--json", "number,reviewDecision,latestReviews,reviewThreads,state,mergedAt,url",
        ], cwd: nil, timeout: 60)
        guard r.status == 0 else { return .windowDropout }
        let view = try decode(RawView.self, r.stdout)
        switch view.state {
        case "MERGED":
            return .merged(atMs: Self.rfc3339ms(view.mergedAt) ?? 0)
        case "CLOSED":
            return .closed
        default:
            return .windowDropout
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw GitHubClientError.decodeFailed
        }
        return value
    }

    private static func detail(from view: RawView) -> PRDetail {
        let threads = (view.reviewThreads ?? []).map { t -> GHReviewThread in
            let first = t.comments?.first
            return GHReviewThread(
                path: t.path ?? "", line: t.line, author: first?.author.login ?? "",
                body: first?.body ?? "", isResolved: t.isResolved
            )
        }
        let approvals = (view.latestReviews ?? [])
            .filter { $0.state == "APPROVED" }
            .compactMap { rfc3339ms($0.submittedAt) }
        return PRDetail(
            number: view.number,
            reviewDecision: view.reviewDecision,
            unresolvedCount: threads.filter { !$0.isResolved }.count,
            lastApprovedReviewAtMs: approvals.max() ?? 0,
            state: view.state,
            mergedAtMs: rfc3339ms(view.mergedAt),
            threads: threads
        )
    }

    private static func rfc3339ms(_ s: String?) -> Int64? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        guard let date = f.date(from: s) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

private struct RawListPR: Decodable {
    struct Author: Decodable { let login: String }
    let number: Int
    let title: String
    let author: Author
    let isDraft: Bool
    let reviewDecision: String?
    let headRefName: String
    let url: String
    let updatedAt: String
}

private struct RawView: Decodable {
    struct Author: Decodable { let login: String }
    struct Review: Decodable { let state: String?; let submittedAt: String? }
    struct Comment: Decodable { let author: Author; let body: String }
    struct Thread: Decodable {
        let isResolved: Bool
        let path: String?
        let line: Int?
        let comments: [Comment]?
    }
    let number: Int
    let reviewDecision: String?
    let state: String
    let mergedAt: String?
    let latestReviews: [Review]?
    let reviewThreads: [Thread]?
}
