import Foundation
import GRDB

/// Reads the latest controlling-terminal device a session recorded on any event —
/// the helper stamps `tty` on every resolvable event, so a session that started
/// before the helper gained a tty still anchors from a later event. The value
/// lives in the raw payload (JSON `tty`); headless sessions stay nil throughout.
public enum TTYAnchor {
    public static func stored(db: DatabaseQueue, sessionId: String) throws -> String? {
        try db.read { conn in
            try String.fetchOne(conn, sql: """
                SELECT json_extract(payload, '$.tty')
                FROM event
                WHERE session_id = ?
                  AND json_extract(payload, '$.tty') IS NOT NULL
                ORDER BY ts DESC, id DESC
                LIMIT 1
                """, arguments: [sessionId])
        }
    }
}
