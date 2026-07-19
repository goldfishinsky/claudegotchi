import Foundation
import GRDB

public struct SessionStop: Equatable {
    public let sessionId: String
    public let cwd: String?
    public let title: String?
    public let tsMs: Int64

    public init(sessionId: String, cwd: String?, title: String?, tsMs: Int64) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.tsMs = tsMs
    }

    public var repoName: String { AgentActivityTracker.repoName(cwd: cwd) }
}

/// A session whose most recent event is a `stop` has finished its turn. Mirrors
/// PermissionWatch's "latest event" test: a later tool event means it resumed,
/// so it is no longer a completion.
public enum CompletionWatch {
    public static let defaultWindowMs: Int64 = 10 * 60 * 1000

    public static func recentCompletions(
        db: DatabaseQueue, nowMs: Int64, windowMs: Int64 = defaultWindowMs,
        filter: SessionFilter = .empty
    ) throws -> [SessionStop] {
        let cutoff = nowMs - windowMs
        return try db.read { conn -> [SessionStop] in
            var stops: [(sid: String, cwd: String?, ts: Int64)] = []
            let cursor = try Row.fetchCursor(conn, sql: """
                SELECT s.session_id AS sid, s.cwd AS cwd, s.ts AS ts
                FROM event s
                WHERE s.type = 'stop'
                  AND s.session_id IS NOT NULL
                  AND s.ts >= ?
                  AND NOT EXISTS (
                    SELECT 1 FROM event e
                    WHERE e.session_id = s.session_id AND e.id > s.id
                  )
                ORDER BY s.ts DESC, s.id DESC
                """, arguments: [cutoff])
            while let r = try cursor.next() {
                stops.append((sid: r["sid"], cwd: r["cwd"], ts: r["ts"]))
            }
            if stops.isEmpty { return [] }

            let ids = stops.map(\.sid)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            var prompts: [String: [String]] = [:]
            let titleCursor = try Row.fetchCursor(conn, sql: """
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

            return stops.compactMap { stop in
                let title = AgentActivityTracker.pickTitle(prompts[stop.sid] ?? [])
                if filter.hides(cwd: stop.cwd, title: title) { return nil }
                return SessionStop(sessionId: stop.sid, cwd: stop.cwd, title: title, tsMs: stop.ts)
            }
        }
    }
}

/// Dedupes completions so one `stop` triggers at most one reveal. The first
/// observation primes a baseline (no reveals for stops that predate launch);
/// afterwards a session emits only when a stop is new or its timestamp advances.
public struct CompletionDetector {
    private var seen: [String: Int64] = [:]
    private var primed: Bool

    public init(primed: Bool = false) { self.primed = primed }

    public mutating func newlyCompleted(_ stops: [SessionStop]) -> [SessionStop] {
        let wasPrimed = primed
        var out: [SessionStop] = []
        for stop in stops {
            let prev = seen[stop.sessionId]
            if let prev {
                if stop.tsMs > prev { out.append(stop) }
            } else if wasPrimed {
                out.append(stop)
            }
            if prev == nil || stop.tsMs > (prev ?? .min) { seen[stop.sessionId] = stop.tsMs }
        }
        primed = true
        return wasPrimed ? out : []
    }
}
