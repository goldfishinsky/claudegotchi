import Foundation
import GRDB

public struct PermissionRequest: Equatable {
    public let sessionId: String
    public let cwd: String?
    public let message: String
    public let ageMs: Int64

    public init(sessionId: String, cwd: String?, message: String, ageMs: Int64) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.message = message
        self.ageMs = ageMs
    }

    public var repoName: String { AgentActivityTracker.repoName(cwd: cwd) }
}

/// Surfaces Claude Code permission-request notifications so the island can alert.
/// A notification is a permission request when its `notification_type` is
/// `permission_prompt` (Claude Code ≥2.1.x) or, on older builds without that
/// field, its message begins with the permission phrase. Empirically verified on
/// Claude Code 2.1.215: message="Claude needs your permission",
/// notification_type="permission_prompt".
public enum PermissionWatch {
    public static let messagePrefix = "Claude needs your permission"
    public static let permissionNotificationType = "permission_prompt"
    public static let defaultMaxAgeMs: Int64 = 10 * 60 * 1000

    public static func isPermissionRequest(notificationType: String?, message: String?) -> Bool {
        if notificationType == permissionNotificationType { return true }
        if let message, message.hasPrefix(messagePrefix) { return true }
        return false
    }

    /// Permission requests still awaiting a response: one is pending until any
    /// later event from the same session supersedes it (the user responded).
    /// At most one entry per session, newest first.
    public static func pending(
        db: DatabaseQueue, nowMs: Int64, maxAgeMs: Int64 = defaultMaxAgeMs,
        filter: SessionFilter = .empty
    ) throws -> [PermissionRequest] {
        let cutoff = nowMs - maxAgeMs
        return try db.read { conn -> [PermissionRequest] in
            let cursor = try Row.fetchCursor(conn, sql: """
                SELECT n.session_id AS sid, n.cwd AS cwd, n.ts AS ts,
                  json_extract(n.payload, '$.message') AS message,
                  json_extract(n.payload, '$.notification_type') AS ntype
                FROM event n
                WHERE n.type = 'notification'
                  AND n.session_id IS NOT NULL
                  AND n.ts >= ?
                  AND NOT EXISTS (
                    SELECT 1 FROM event e
                    WHERE e.session_id = n.session_id AND e.id > n.id
                  )
                ORDER BY n.ts DESC, n.id DESC
                """, arguments: [cutoff])
            var out: [PermissionRequest] = []
            while let r = try cursor.next() {
                let ntype: String? = r["ntype"]
                let message: String? = r["message"]
                guard isPermissionRequest(notificationType: ntype, message: message) else { continue }
                let cwd: String? = r["cwd"]
                if filter.hides(cwd: cwd, title: nil) { continue }
                let sid: String = r["sid"]
                let ts: Int64 = r["ts"]
                out.append(PermissionRequest(
                    sessionId: sid, cwd: cwd,
                    message: message ?? messagePrefix, ageMs: max(0, nowMs - ts)
                ))
            }
            return out
        }
    }
}
