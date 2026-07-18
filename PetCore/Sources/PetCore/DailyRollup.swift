import Foundation
import GRDB

public struct DailyRollup: Equatable {
    public let date: String
    public let sessions: Int
    public let messages: Int
    public let tokensIn: Int
    public let tokensOut: Int
    public let toolsUsed: Int

    public static func upsert(
        eventDate: String,
        type: Event.EventType,
        tokensIn: Int,
        tokensOut: Int,
        tool: String?,
        in conn: GRDB.Database
    ) throws {
        try conn.execute(sql: """
            INSERT INTO daily_rollup (date, sessions, messages, tokens_in, tokens_out, tools_used)
            VALUES (?, 0, 0, 0, 0, 0)
            ON CONFLICT(date) DO NOTHING
            """, arguments: [eventDate])

        switch type {
        case .sessionStart:
            try conn.execute(sql: "UPDATE daily_rollup SET sessions = sessions + 1 WHERE date = ?", arguments: [eventDate])
        case .postToolUse:
            try conn.execute(sql: """
                UPDATE daily_rollup
                SET messages = messages + 1,
                    tools_used = tools_used + 1,
                    tokens_in = tokens_in + ?,
                    tokens_out = tokens_out + ?
                WHERE date = ?
                """, arguments: [tokensIn, tokensOut, eventDate])
        case .stop:
            try conn.execute(sql: """
                UPDATE daily_rollup
                SET tokens_in = tokens_in + ?,
                    tokens_out = tokens_out + ?
                WHERE date = ?
                """, arguments: [tokensIn, tokensOut, eventDate])
        default:
            break
        }
    }

    public static func fetch(date: String, from conn: GRDB.Database) throws -> DailyRollup? {
        let row = try Row.fetchOne(conn, sql: "SELECT * FROM daily_rollup WHERE date = ?", arguments: [date])
        guard let r = row else { return nil }
        return DailyRollup(
            date: r["date"], sessions: r["sessions"], messages: r["messages"],
            tokensIn: r["tokens_in"], tokensOut: r["tokens_out"], toolsUsed: r["tools_used"]
        )
    }
}
