import Foundation
import GRDB

/// Reads the controlling-terminal device a session recorded at `session_start`.
/// The value lives in the raw event payload (JSON `tty`), so no schema column is
/// needed; headless sessions stored nil and resolve to nil here.
public enum TTYAnchor {
    public static func stored(db: DatabaseQueue, sessionId: String) throws -> String? {
        try db.read { conn in
            try String.fetchOne(conn, sql: """
                SELECT json_extract(payload, '$.tty')
                FROM event
                WHERE session_id = ? AND type = 'session_start'
                  AND json_extract(payload, '$.tty') IS NOT NULL
                ORDER BY ts DESC, id DESC
                LIMIT 1
                """, arguments: [sessionId])
        }
    }
}
