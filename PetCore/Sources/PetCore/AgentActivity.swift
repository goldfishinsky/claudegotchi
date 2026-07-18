import Foundation
import GRDB

public struct AgentActivity: Equatable {
    public enum State: String, Equatable {
        case working
        case idle
    }

    public let sessionId: String
    public let repoName: String
    public let state: State
    public let sessionTokens: Int64
    public let ratePerMin: Int64
    public let model: String?
    public let title: String?

    public init(sessionId: String, repoName: String, state: State,
                sessionTokens: Int64, ratePerMin: Int64, model: String?,
                title: String? = nil) {
        self.sessionId = sessionId
        self.repoName = repoName
        self.state = state
        self.sessionTokens = sessionTokens
        self.ratePerMin = ratePerMin
        self.model = model
        self.title = title
    }
}

public enum AgentActivityTracker {
    public static let workingWindowMs: Int64 = 120_000
    public static let rateWindowMs: Int64 = 60_000

    public static func activeAgents(
        db: DatabaseQueue, nowMs: Int64, windowMs: Int64,
        workingWindowMs: Int64 = AgentActivityTracker.workingWindowMs
    ) throws -> [AgentActivity] {
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: nowMs, windowMs: windowMs, repoPaths: []
        )
        if sessions.isEmpty { return [] }

        let ids = sessions.map(\.sessionId)
        let rateCutoff = nowMs - rateWindowMs
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")

        let (totals, rates, models, titles) = try db.read {
            conn -> ([String: Int64], [String: Int64], [String: String], [String: String]) in
            var totals: [String: Int64] = [:]
            var rates: [String: Int64] = [:]
            let tokenArgs: [any DatabaseValueConvertible] =
                [rateCutoff, rateCutoff] + ids.map { $0 as any DatabaseValueConvertible }
            let tokenCursor = try GRDB.Row.fetchCursor(conn, sql: """
                SELECT session_id,
                  COALESCE(SUM(json_extract(payload, '$.tokens_in')), 0)
                  + COALESCE(SUM(json_extract(payload, '$.tokens_out')), 0) AS total,
                  COALESCE(SUM(CASE WHEN ts >= ? THEN json_extract(payload, '$.tokens_in') ELSE 0 END), 0)
                  + COALESCE(SUM(CASE WHEN ts >= ? THEN json_extract(payload, '$.tokens_out') ELSE 0 END), 0) AS rate
                FROM event
                WHERE type IN ('post_tool_use', 'stop') AND session_id IN (\(placeholders))
                GROUP BY session_id
                """, arguments: StatementArguments(tokenArgs))
            while let r = try tokenCursor.next() {
                let sid: String = r["session_id"]
                totals[sid] = r["total"]
                rates[sid] = r["rate"]
            }

            var models: [String: String] = [:]
            let modelCursor = try GRDB.Row.fetchCursor(conn, sql: """
                SELECT session_id, json_extract(payload, '$.model') AS model
                FROM event
                WHERE session_id IN (\(placeholders))
                  AND json_extract(payload, '$.model') IS NOT NULL
                ORDER BY ts ASC, id ASC
                """, arguments: StatementArguments(ids))
            while let r = try modelCursor.next() {
                let sid: String = r["session_id"]
                if let m: String = r["model"] { models[sid] = m }
            }

            var titles: [String: String] = [:]
            let titleCursor = try GRDB.Row.fetchCursor(conn, sql: """
                SELECT session_id, json_extract(payload, '$.prompt') AS prompt
                FROM event
                WHERE type = 'user_prompt_submit' AND session_id IN (\(placeholders))
                  AND json_extract(payload, '$.prompt') IS NOT NULL
                ORDER BY ts ASC, id ASC
                """, arguments: StatementArguments(ids))
            while let r = try titleCursor.next() {
                let sid: String = r["session_id"]
                if titles[sid] == nil, let p: String = r["prompt"] { titles[sid] = p }
            }
            return (totals, rates, models, titles)
        }

        return sessions
            .sorted { a, b in
                let aw = a.lastActivityMs >= nowMs - workingWindowMs
                let bw = b.lastActivityMs >= nowMs - workingWindowMs
                if aw != bw { return aw }
                return a.lastActivityMs > b.lastActivityMs
            }
            .map { s in
                let working = s.lastActivityMs >= nowMs - workingWindowMs
                return AgentActivity(
                    sessionId: s.sessionId,
                    repoName: repoName(cwd: s.cwd),
                    state: working ? .working : .idle,
                    sessionTokens: totals[s.sessionId] ?? 0,
                    ratePerMin: rates[s.sessionId] ?? 0,
                    model: models[s.sessionId].map(shortModel),
                    title: titles[s.sessionId]
                )
            }
    }

    static func repoName(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "未知目录" }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.split(separator: "/").last.map(String.init) ?? "未知目录"
    }

    static func shortModel(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }
        let parts = s.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            s = parts.dropLast().joined(separator: "-")
        }
        return s
    }
}
