import Foundation
import GRDB

public enum LeaderboardPayload {
    public static func build(db: DatabaseQueue, nowMs: Int64) throws -> SyncPayload? {
        let petCount = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pet") ?? 0 }
        guard petCount > 0 else { return nil }

        let petSnapshot: SyncPayload.PetSnapshot? = try Pet.fetchAlive(from: db).map {
            SyncPayload.PetSnapshot(
                uid: $0.uid ?? ULID.generate(),
                species: $0.species, name: $0.name,
                birthdayMs: $0.birthday, xp: $0.xp
            )
        }

        let best = try StatsQueries.bestSurvivalMs(db, nowMs: nowMs).map {
            SyncPayload.Best(survivalMs: $0.survivalMs, species: $0.species, name: $0.name)
        }

        let (tokensIn, tokensOut) = try StatsQueries.lifetimeTokenSplit(db)
        let (sessions, tools): (Int64, Int64) = try db.read { conn in
            guard let row = try Row.fetchOne(conn, sql: """
                SELECT COALESCE(SUM(sessions), 0) AS s, COALESCE(SUM(tools_used), 0) AS t
                FROM daily_rollup
                """) else { return (0, 0) }
            return (row["s"], row["t"])
        }
        let totals = SyncPayload.Totals(tokensIn: tokensIn, tokensOut: tokensOut, sessions: sessions, toolsUsed: tools)

        let usages = try ModelUsageStore.all(in: db)
        var models: [String: SyncPayload.ModelCounts] = [:]
        for usage in usages {
            models[usage.model] = SyncPayload.ModelCounts(in: usage.tokensIn, out: usage.tokensOut, calls: usage.calls)
        }
        let platform = ModelPlatform.dominant(models: usages)

        return SyncPayload(platform: platform, totals: totals, pet: petSnapshot, best: best, models: models)
    }
}
