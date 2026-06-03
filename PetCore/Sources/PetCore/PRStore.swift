import Foundation
import GRDB

public enum PRStore {
    public static func upsertPRs(_ prs: [PR], in db: DatabaseQueue) throws {
        try db.write { conn in
            for pr in prs {
                try conn.execute(sql: """
                    INSERT INTO pr
                      (repo_slug, number, title, author, state, is_draft, review_decision,
                       unresolved_count, last_approved_review_at, head_branch, url,
                       updated_at, is_mine, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(repo_slug, number) DO UPDATE SET
                      title = excluded.title,
                      author = excluded.author,
                      state = excluded.state,
                      is_draft = excluded.is_draft,
                      review_decision = excluded.review_decision,
                      unresolved_count = excluded.unresolved_count,
                      last_approved_review_at = excluded.last_approved_review_at,
                      head_branch = excluded.head_branch,
                      url = excluded.url,
                      updated_at = excluded.updated_at,
                      is_mine = excluded.is_mine,
                      fetched_at = excluded.fetched_at
                    """, arguments: [
                    pr.repoSlug, pr.number, pr.title, pr.author, pr.state,
                    pr.isDraft, pr.reviewDecision, pr.unresolvedCount,
                    pr.lastApprovedReviewAt, pr.headBranch, pr.url,
                    pr.updatedAt, pr.isMine, pr.fetchedAt
                ])
            }
        }
    }

    public static func allPRs(in db: DatabaseQueue) throws -> [PR] {
        try db.read { try PR.fetchAll($0) }
    }

    public static func addRepo(slug: String, localPath: String?, enabled: Bool,
                               in db: DatabaseQueue) throws -> WatchedRepo {
        try db.write { conn in
            var repo = WatchedRepo(id: nil, slug: slug, localPath: localPath, enabled: enabled)
            try repo.insert(conn)
            return repo
        }
    }

    public static func removeRepo(id: Int64, in db: DatabaseQueue) throws {
        try db.write { conn in
            try conn.execute(sql: "DELETE FROM watched_author WHERE repo_id = ?", arguments: [id])
            try conn.execute(sql: "DELETE FROM watched_repo WHERE id = ?", arguments: [id])
        }
    }

    public static func watchedRepos(in db: DatabaseQueue) throws -> [WatchedRepo] {
        try db.read { try WatchedRepo.order(Column("id")).fetchAll($0) }
    }

    @discardableResult
    public static func addAuthor(repoId: Int64, login: String, in db: DatabaseQueue) throws -> WatchedAuthor {
        try db.write { conn in
            var author = WatchedAuthor(id: nil, repoId: repoId, login: login)
            try author.insert(conn)
            return author
        }
    }

    public static func removeAuthor(id: Int64, in db: DatabaseQueue) throws {
        try db.write { conn in
            try conn.execute(sql: "DELETE FROM watched_author WHERE id = ?", arguments: [id])
        }
    }

    public static func authors(repoId: Int64, in db: DatabaseQueue) throws -> [WatchedAuthor] {
        try db.read {
            try WatchedAuthor.filter(Column("repo_id") == repoId).order(Column("id")).fetchAll($0)
        }
    }
}
