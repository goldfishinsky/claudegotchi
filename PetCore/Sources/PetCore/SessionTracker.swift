import Foundation
import GRDB

public struct ActiveSession: Equatable {
    public let sessionId: String
    public let cwd: String?
    public let repo: String
    public let startedAtMs: Int64
    public let lastActivityMs: Int64
    public let lastTool: String?

    public init(sessionId: String, cwd: String?, repo: String,
                startedAtMs: Int64, lastActivityMs: Int64, lastTool: String?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.repo = repo
        self.startedAtMs = startedAtMs
        self.lastActivityMs = lastActivityMs
        self.lastTool = lastTool
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
            let stoppedAfterStart = rows.contains { $0.type == "stop" && $0.ts >= start.ts }
            if stoppedAfterStart { continue }
            guard let last = rows.max(by: { $0.ts < $1.ts }) else { continue }
            if last.ts < cutoff { continue }

            let cwd = last.cwd ?? start.cwd
            result.append(ActiveSession(
                sessionId: sid,
                cwd: cwd,
                repo: repoLabel(cwd: cwd, repoPaths: repoPaths),
                startedAtMs: start.ts,
                lastActivityMs: last.ts,
                lastTool: toolFromPayload(last.payload)
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
}
