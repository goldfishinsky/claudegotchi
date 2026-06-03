import Foundation
import GRDB

public enum FixJobState: String, Codable {
    case queued, checkout, running, succeeded, failed, canceled
}

public struct FixJob: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var id: Int64?
    public var prRowid: Int64
    public var repoSlug: String
    public var prNumber: Int
    public var state: FixJobState
    public var prompt: String?
    public var worktreePath: String?
    public var startedAt: Int64?
    public var endedAt: Int64?
    public var exitCode: Int32?
    public var error: String?
    public var logPath: String?
    public var commitSha: String?
    public var createdAt: Int64

    public static let databaseTableName = "fix_job"

    enum CodingKeys: String, CodingKey {
        case id
        case prRowid = "pr_rowid"
        case repoSlug = "repo_slug"
        case prNumber = "pr_number"
        case state, prompt
        case worktreePath = "worktree_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case exitCode = "exit_code"
        case error
        case logPath = "log_path"
        case commitSha = "commit_sha"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(
        id: Int64? = nil, prRowid: Int64, repoSlug: String, prNumber: Int,
        state: FixJobState, prompt: String? = nil, worktreePath: String? = nil,
        startedAt: Int64? = nil, endedAt: Int64? = nil, exitCode: Int32? = nil,
        error: String? = nil, logPath: String? = nil, commitSha: String? = nil,
        createdAt: Int64
    ) {
        self.id = id
        self.prRowid = prRowid
        self.repoSlug = repoSlug
        self.prNumber = prNumber
        self.state = state
        self.prompt = prompt
        self.worktreePath = worktreePath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.error = error
        self.logPath = logPath
        self.commitSha = commitSha
        self.createdAt = createdAt
    }
}

public enum FixJobMachine {
    public static func next(_ state: FixJobState, exit: Int32?, canceled: Bool) -> FixJobState {
        switch state {
        case .succeeded, .failed, .canceled:
            return state
        default:
            break
        }
        if canceled { return .canceled }
        switch state {
        case .queued:
            return .checkout
        case .checkout:
            return .running
        case .running:
            guard let code = exit else { return .running }
            return code == 0 ? .succeeded : .failed
        default:
            return state
        }
    }

    public static func canStart(prIsMine: Bool, localPathValid: Bool, hasActiveJob: Bool) -> Bool {
        prIsMine && localPathValid && !hasActiveJob
    }
}

public enum FixJobStore {
    public static func job(id: Int64, in conn: GRDB.Database) throws -> FixJob? {
        try FixJob.fetchOne(conn, sql: "SELECT * FROM fix_job WHERE id = ?", arguments: [id])
    }

    public static func history(limit: Int, in conn: GRDB.Database) throws -> [FixJob] {
        try FixJob.fetchAll(
            conn, sql: "SELECT * FROM fix_job ORDER BY created_at DESC LIMIT ?",
            arguments: [limit]
        )
    }

    public static func activeJob(repoSlug: String, in conn: GRDB.Database) throws -> FixJob? {
        try FixJob.fetchOne(
            conn,
            sql: "SELECT * FROM fix_job WHERE repo_slug = ? AND state IN ('running','checkout') ORDER BY id DESC LIMIT 1",
            arguments: [repoSlug]
        )
    }

    public static func inFlightJobs(in conn: GRDB.Database) throws -> [FixJob] {
        try FixJob.fetchAll(
            conn, sql: "SELECT * FROM fix_job WHERE state IN ('running','checkout') ORDER BY id"
        )
    }

    public static func queuedJobs(in conn: GRDB.Database) throws -> [FixJob] {
        try FixJob.fetchAll(
            conn, sql: "SELECT * FROM fix_job WHERE state = 'queued' ORDER BY created_at"
        )
    }

    public static func markCheckout(
        id: Int64, worktreePath: String, startedAt: Int64, in conn: GRDB.Database
    ) throws {
        try conn.execute(sql: """
            UPDATE fix_job SET state = ?, worktree_path = ?, started_at = ? WHERE id = ?
            """, arguments: [FixJobState.checkout.rawValue, worktreePath, startedAt, id])
    }

    public static func setPrompt(id: Int64, prompt: String, in conn: GRDB.Database) throws {
        try conn.execute(sql: "UPDATE fix_job SET prompt = ? WHERE id = ?",
                         arguments: [prompt, id])
    }

    public static func markRunning(id: Int64, logPath: String, in conn: GRDB.Database) throws {
        try conn.execute(sql: """
            UPDATE fix_job SET state = ?, log_path = ? WHERE id = ?
            """, arguments: [FixJobState.running.rawValue, logPath, id])
    }

    public static func finish(
        id: Int64, state: FixJobState, exitCode: Int32?, commitSha: String?,
        logPath: String?, error: String?, endedAt: Int64, in conn: GRDB.Database
    ) throws {
        try conn.execute(sql: """
            UPDATE fix_job
            SET state = ?, exit_code = ?, commit_sha = ?, log_path = ?, error = ?, ended_at = ?
            WHERE id = ?
            """, arguments: [state.rawValue, exitCode, commitSha, logPath, error, endedAt, id])
    }
}
