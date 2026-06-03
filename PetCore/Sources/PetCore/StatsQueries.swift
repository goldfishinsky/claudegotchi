import Foundation
import GRDB

public struct TodayTotals: Equatable {
    public let tokens: Int64
    public let sessions: Int
    public let tools: Int
    public init(tokens: Int64, sessions: Int, tools: Int) {
        self.tokens = tokens; self.sessions = sessions; self.tools = tools
    }
}

public struct GrowthEntry: Equatable {
    public let species: String
    public let name: String?
    public let bornMs: Int64
    public let diedMs: Int64?
    public let xp: Int64
    public init(species: String, name: String?, bornMs: Int64, diedMs: Int64?, xp: Int64) {
        self.species = species; self.name = name
        self.bornMs = bornMs; self.diedMs = diedMs; self.xp = xp
    }
}

public enum StatsQueries {
    public static func lifetimeTokens(_ db: DatabaseQueue) throws -> Int64 {
        try db.read {
            try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(tokens_in + tokens_out), 0) FROM daily_rollup") ?? 0
        }
    }

    public static func todayTotals(_ db: DatabaseQueue, nowMs: Int64, tz: TimeZone) throws -> TodayTotals {
        let key = LocalDay.key(unixMs: nowMs, timeZone: tz)
        return try db.read { conn in
            guard let row = try Row.fetchOne(conn, sql: """
                SELECT tokens_in, tokens_out, sessions, tools_used
                FROM daily_rollup WHERE date = ?
                """, arguments: [key]) else {
                return TodayTotals(tokens: 0, sessions: 0, tools: 0)
            }
            let tin: Int64 = row["tokens_in"]
            let tout: Int64 = row["tokens_out"]
            return TodayTotals(tokens: tin + tout, sessions: row["sessions"], tools: row["tools_used"])
        }
    }

    public static func activeStreakDays(_ db: DatabaseQueue, nowMs: Int64, tz: TimeZone) throws -> Int {
        let dates = try db.read { try String.fetchAll($0, sql: "SELECT date FROM daily_rollup") }
        let present = Set(dates.map { dayIndexFromKey($0, tz: tz) })
        var idx = LocalDay.dayIndex(unixMs: nowMs, timeZone: tz)
        var streak = 0
        while present.contains(idx) {
            streak += 1
            idx -= 1
        }
        return streak
    }

    public static func peakDayTokens(_ db: DatabaseQueue) throws -> Int64 {
        try db.read {
            try Int64.fetchOne($0, sql: "SELECT COALESCE(MAX(tokens_in + tokens_out), 0) FROM daily_rollup") ?? 0
        }
    }

    public static func heatmapSeries(_ db: DatabaseQueue, weeks: Int, nowMs: Int64, tz: TimeZone) throws -> [(day: String, tokens: Int64)] {
        let totalDays = weeks * 7
        let byKey: [String: Int64] = try db.read { conn in
            var acc: [String: Int64] = [:]
            let cursor = try Row.fetchCursor(conn, sql: "SELECT date, tokens_in + tokens_out AS t FROM daily_rollup")
            while let r = try cursor.next() {
                acc[r["date"]] = r["t"]
            }
            return acc
        }
        var out: [(day: String, tokens: Int64)] = []
        for offset in stride(from: totalDays - 1, through: 0, by: -1) {
            let ms = nowMs - Int64(offset) * 86_400_000
            let key = LocalDay.key(unixMs: ms, timeZone: tz)
            out.append((day: key, tokens: byKey[key] ?? 0))
        }
        return out
    }

    public static func modelUsage(_ db: DatabaseQueue) throws -> [ModelUsage] {
        try ModelUsageStore.all(in: db)
    }

    public static func petAgeDays(_ db: DatabaseQueue, nowMs: Int64) throws -> Int {
        guard let pet = try Pet.fetchAlive(from: db) else { return 0 }
        return Int((nowMs - pet.birthday) / 86_400_000)
    }

    public static func growthHistory(_ db: DatabaseQueue, limit: Int) throws -> [GrowthEntry] {
        try db.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT species, name, birthday, death_at, xp
                FROM pet WHERE death_at IS NOT NULL
                ORDER BY death_at DESC LIMIT ?
                """, arguments: [limit])
            return rows.map {
                GrowthEntry(
                    species: $0["species"], name: $0["name"],
                    bornMs: $0["birthday"], diedMs: $0["death_at"], xp: $0["xp"]
                )
            }
        }
    }

    private static func dayIndexFromKey(_ key: String, tz: TimeZone) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        guard let date = f.date(from: key) else { return Int.min }
        // Anchor at local noon so a DST shift never bumps the index.
        let noonMs = Int64(date.timeIntervalSince1970 * 1000) + 12 * 3_600_000
        return LocalDay.dayIndex(unixMs: noonMs, timeZone: tz)
    }
}
