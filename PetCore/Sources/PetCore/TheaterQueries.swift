import Foundation
import GRDB

/// Lightweight lookups that feed live `TheaterSignals`: the latest token-bearing
/// Stop, the latest PR celebration, and the latest pet click.
public enum TheaterQueries {
    public struct TokenStop: Equatable {
        public let ts: Int64
        public let tokens: Int64
        public init(ts: Int64, tokens: Int64) { self.ts = ts; self.tokens = tokens }
    }

    public static func latestTokenStop(_ db: DatabaseQueue, sinceMs: Int64) throws -> TokenStop? {
        try db.read { conn in
            guard let row = try Row.fetchOne(conn, sql: """
                SELECT ts,
                  COALESCE(json_extract(payload, '$.tokens_in'), 0)
                  + COALESCE(json_extract(payload, '$.tokens_out'), 0) AS tokens
                FROM event
                WHERE type = 'stop' AND ts >= ?
                  AND (COALESCE(json_extract(payload, '$.tokens_in'), 0)
                       + COALESCE(json_extract(payload, '$.tokens_out'), 0)) > 0
                ORDER BY ts DESC, id DESC
                LIMIT 1
                """, arguments: [sinceMs]) else { return nil }
            return TokenStop(ts: row["ts"], tokens: row["tokens"])
        }
    }

    public static func latestPRCelebrationMs(_ db: DatabaseQueue, sinceMs: Int64) throws -> Int64? {
        try db.read { conn in
            try Int64.fetchOne(conn, sql: """
                SELECT MAX(ts) FROM event
                WHERE type IN ('pr_merged', 'pr_approved') AND ts >= ?
                """, arguments: [sinceMs])
        }
    }

    public static func latestClickMs(_ db: DatabaseQueue) throws -> Int64? {
        try db.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT MAX(ts) FROM event WHERE type = 'pet_click'")
        }
    }

    /// Most recent event of any kind — the wall clock for "how long since the
    /// machine did anything", which drives the stroll → calm-idle transition.
    public static func latestEventMs(_ db: DatabaseQueue) throws -> Int64? {
        try db.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT MAX(ts) FROM event")
        }
    }
}
