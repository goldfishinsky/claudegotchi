import Foundation
import GRDB

public struct PR: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var id: Int64?
    public var repoSlug: String
    public var number: Int
    public var title: String
    public var author: String
    public var state: String
    public var isDraft: Bool
    public var reviewDecision: String?
    public var unresolvedCount: Int
    public var lastApprovedReviewAt: Int64
    public var headBranch: String
    public var url: String
    public var updatedAt: Int64
    public var isMine: Bool
    public var fetchedAt: Int64

    public static let databaseTableName = "pr"

    enum CodingKeys: String, CodingKey {
        case id
        case repoSlug = "repo_slug"
        case number, title, author, state
        case isDraft = "is_draft"
        case reviewDecision = "review_decision"
        case unresolvedCount = "unresolved_count"
        case lastApprovedReviewAt = "last_approved_review_at"
        case headBranch = "head_branch"
        case url
        case updatedAt = "updated_at"
        case isMine = "is_mine"
        case fetchedAt = "fetched_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(
        id: Int64?, repoSlug: String, number: Int, title: String, author: String,
        state: String, isDraft: Bool, reviewDecision: String?, unresolvedCount: Int,
        lastApprovedReviewAt: Int64, headBranch: String, url: String,
        updatedAt: Int64, isMine: Bool, fetchedAt: Int64
    ) {
        self.id = id
        self.repoSlug = repoSlug
        self.number = number
        self.title = title
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.unresolvedCount = unresolvedCount
        self.lastApprovedReviewAt = lastApprovedReviewAt
        self.headBranch = headBranch
        self.url = url
        self.updatedAt = updatedAt
        self.isMine = isMine
        self.fetchedAt = fetchedAt
    }
}

public struct WatchedRepo: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var id: Int64?
    public var slug: String
    public var localPath: String?
    public var enabled: Bool

    public static let databaseTableName = "watched_repo"

    enum CodingKeys: String, CodingKey {
        case id, slug
        case localPath = "local_path"
        case enabled
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(id: Int64?, slug: String, localPath: String?, enabled: Bool) {
        self.id = id
        self.slug = slug
        self.localPath = localPath
        self.enabled = enabled
    }
}

public struct WatchedAuthor: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var id: Int64?
    public var repoId: Int64
    public var login: String

    public static let databaseTableName = "watched_author"

    enum CodingKeys: String, CodingKey {
        case id
        case repoId = "repo_id"
        case login
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(id: Int64?, repoId: Int64, login: String) {
        self.id = id
        self.repoId = repoId
        self.login = login
    }
}
