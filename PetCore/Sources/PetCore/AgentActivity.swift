import Foundation
import GRDB

public struct AgentActivity: Equatable {
    public enum State: String, Equatable {
        case working
        case idle
    }

    public let sessionId: String
    public let repoName: String
    public let repoLabel: String
    public let state: State
    public let sessionTokens: Int64
    public let ratePerMin: Int64
    public let model: String?
    public let title: String?
    public let currentTool: String?
    public let currentToolStartedMs: Int64?
    public let cwd: String?

    public init(sessionId: String, repoName: String, state: State,
                sessionTokens: Int64, ratePerMin: Int64, model: String?,
                title: String? = nil, repoLabel: String? = nil,
                currentTool: String? = nil, currentToolStartedMs: Int64? = nil,
                cwd: String? = nil) {
        self.sessionId = sessionId
        self.repoName = repoName
        self.repoLabel = repoLabel ?? repoName
        self.state = state
        self.sessionTokens = sessionTokens
        self.ratePerMin = ratePerMin
        self.model = model
        self.title = title
        self.currentTool = currentTool
        self.currentToolStartedMs = currentToolStartedMs
        self.cwd = cwd
    }

    /// Codex sessions are namespaced `codex-<uuid>` by the hook helper at spool time.
    public var isCodex: Bool { sessionId.hasPrefix("codex-") }
    public var platform: String { isCodex ? "codex" : "claude-code" }
}

public enum AgentActivityTracker {
    public static let workingWindowMs: Int64 = 120_000
    public static let rateWindowMs: Int64 = 60_000

    public static func activeAgents(
        db: DatabaseQueue, nowMs: Int64, windowMs: Int64,
        workingWindowMs: Int64 = AgentActivityTracker.workingWindowMs,
        filter: SessionFilter = .empty
    ) throws -> [AgentActivity] {
        let sessions = try SessionTracker.activeSessions(
            db: db, nowMs: nowMs, windowMs: windowMs, repoPaths: []
        )
        if sessions.isEmpty { return [] }

        let ids = sessions.map(\.sessionId)
        let rateCutoff = nowMs - rateWindowMs
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")

        let (totals, rates, models, titles, actions) = try db.read {
            conn -> ([String: Int64], [String: Int64], [String: String], [String: String],
                     [String: (tool: String, ts: Int64)]) in
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

            var prompts: [String: [String]] = [:]
            let titleCursor = try GRDB.Row.fetchCursor(conn, sql: """
                SELECT session_id, json_extract(payload, '$.prompt') AS prompt
                FROM event
                WHERE type = 'user_prompt_submit' AND session_id IN (\(placeholders))
                  AND json_extract(payload, '$.prompt') IS NOT NULL
                ORDER BY ts ASC, id ASC
                """, arguments: StatementArguments(ids))
            while let r = try titleCursor.next() {
                let sid: String = r["session_id"]
                if let p: String = r["prompt"] { prompts[sid, default: []].append(p) }
            }
            let titles = prompts.compactMapValues(pickTitle)

            var actions: [String: (tool: String, ts: Int64)] = [:]
            let actionCursor = try GRDB.Row.fetchCursor(conn, sql: """
                SELECT session_id, json_extract(payload, '$.tool') AS tool, ts
                FROM event
                WHERE type IN ('pre_tool_use', 'post_tool_use') AND session_id IN (\(placeholders))
                  AND json_extract(payload, '$.tool') IS NOT NULL
                ORDER BY ts ASC, id ASC
                """, arguments: StatementArguments(ids))
            while let r = try actionCursor.next() {
                let sid: String = r["session_id"]
                if let tool: String = r["tool"] { actions[sid] = (tool, r["ts"]) }
            }
            return (totals, rates, models, titles, actions)
        }

        // A session running background tasks stays working past the idle window;
        // its own turn has stopped, so no live tool is shown for it.
        func isWorking(_ s: ActiveSession) -> Bool {
            s.backgroundTasks > 0 || s.lastActivityMs >= nowMs - workingWindowMs
        }
        let ordered = sessions
            .filter { !filter.hides(cwd: $0.cwd, title: titles[$0.sessionId]) }
            .sorted { a, b in
                let aw = isWorking(a)
                let bw = isWorking(b)
                if aw != bw { return aw }
                return a.lastActivityMs > b.lastActivityMs
            }
        let labels = SessionRepo.labels(cwds: ordered.map(\.cwd))
        return ordered.enumerated().map { idx, s in
            let working = isWorking(s)
            let action = (working && s.backgroundTasks == 0) ? actions[s.sessionId] : nil
            return AgentActivity(
                sessionId: s.sessionId,
                repoName: repoName(cwd: s.cwd),
                state: working ? .working : .idle,
                sessionTokens: totals[s.sessionId] ?? 0,
                ratePerMin: rates[s.sessionId] ?? 0,
                model: models[s.sessionId].map(shortModel),
                title: titles[s.sessionId],
                repoLabel: labels[idx],
                currentTool: action?.tool,
                currentToolStartedMs: action?.ts,
                cwd: s.cwd
            )
        }
    }

    // Harness-injected prompts (task notifications, slash-command wrappers,
    // system reminders) precede the human's first prompt; skip them for titles.
    // Sourced from the prompt-prefix presets so the list is user-visible.
    static let titleNoisePrefixes = SessionFilterPresets.promptPrefixPatterns

    static func pickTitle(_ prompts: [String]) -> String? {
        guard let first = prompts.first else { return nil }
        for p in prompts {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if !titleNoisePrefixes.contains(where: trimmed.hasPrefix) { return p }
        }
        return first
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
