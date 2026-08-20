import Foundation
import GRDB

public struct ActiveSession: Equatable {
    public let sessionId: String
    public let platform: String
    public let cwd: String?
    public let repo: String
    public let startedAtMs: Int64
    public let lastActivityMs: Int64
    public let lastTool: String?
    /// Background tasks still pending on the session's latest `stop` (0 when the
    /// latest event is not a stop, or the stop carried none).
    public let backgroundTasks: Int

    public init(sessionId: String, platform: String = ModelPlatform.claudeCode,
                cwd: String?, repo: String,
                startedAtMs: Int64, lastActivityMs: Int64, lastTool: String?,
                backgroundTasks: Int = 0) {
        self.sessionId = sessionId
        self.platform = platform
        self.cwd = cwd
        self.repo = repo
        self.startedAtMs = startedAtMs
        self.lastActivityMs = lastActivityMs
        self.lastTool = lastTool
        self.backgroundTasks = backgroundTasks
    }
}

public enum SessionTracker {
    private struct Row {
        let type: String
        let ts: Int64
        let cwd: String?
        let payload: String?
    }

    public static func activeSessions(
        db: DatabaseQueue, nowMs: Int64, windowMs: Int64,
        repoPaths: [(slug: String, path: String)]
    ) throws -> [ActiveSession] {
        let cutoff = nowMs - windowMs
        let grouped: [String: [Row]] = try db.read { conn in
            let cursor = try GRDB.Row.fetchCursor(conn, sql: """
                SELECT session_id, type, ts, cwd, payload
                FROM event
                WHERE session_id IS NOT NULL AND type IN
                  ('session_start', 'pre_tool_use', 'post_tool_use', 'stop',
                   'notification', 'hibernate_start', 'hibernate_end')
                ORDER BY ts ASC, id ASC
                """)
            var acc: [String: [Row]] = [:]
            while let r = try cursor.next() {
                let sid: String = r["session_id"]
                acc[sid, default: []].append(Row(
                    type: r["type"], ts: r["ts"], cwd: r["cwd"], payload: r["payload"]
                ))
            }
            return acc
        }

        var result: [ActiveSession] = []
        for (sid, rows) in grouped {
            guard let start = rows.first(where: { $0.type == "session_start" }) else { continue }
            // Rows arrive ts ASC, id ASC. Claude emits `stop` once per turn, so a
            // session is closed only when its most recent event is a stop; any
            // later tool call means it resumed.
            guard let last = rows.last else { continue }
            let bgTasks = backgroundTasks(last.payload)
            // A stop closes the session only once its background work drains; a
            // stop that still lists subagents/shells keeps the session working.
            if last.type == "stop" && bgTasks == 0 { continue }
            if last.ts < cutoff { continue }

            let cwd = last.cwd ?? start.cwd
            let platform = rows.reversed().compactMap { platformFromPayload($0.payload) }.first
                ?? (sid.hasPrefix("codex-") ? ModelPlatform.codex : ModelPlatform.claudeCode)
            result.append(ActiveSession(
                sessionId: sid,
                platform: platform,
                cwd: cwd,
                repo: repoLabel(cwd: cwd, repoPaths: repoPaths),
                startedAtMs: start.ts,
                lastActivityMs: last.ts,
                lastTool: toolFromPayload(last.payload),
                backgroundTasks: bgTasks
            ))
        }
        return result.sorted { $0.startedAtMs < $1.startedAtMs }
    }

    private static func repoLabel(cwd: String?, repoPaths: [(slug: String, path: String)]) -> String {
        guard let cwd, !cwd.isEmpty else { return "(unknown)" }
        let matches = repoPaths.filter { cwd == $0.path || cwd.hasPrefix($0.path + "/") }
        if let best = matches.max(by: { $0.path.count < $1.path.count }) {
            return basename(best.path)
        }
        return basename(cwd)
    }

    private static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private static func toolFromPayload(_ payload: String?) -> String? {
        guard let payload, let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["tool"] as? String
    }

    private static func platformFromPayload(_ payload: String?) -> String? {
        guard let payload, let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platform = obj["platform"] as? String, !platform.isEmpty
        else { return nil }
        return platform
    }

    private static func backgroundTasks(_ payload: String?) -> Int {
        guard let payload, let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }
        return obj["background_tasks"] as? Int ?? 0
    }
}
