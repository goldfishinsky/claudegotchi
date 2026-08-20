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
        var platformModels: [String: [String: SyncPayload.ModelCounts]] = [:]
        var platformTokens: [String: (tokensIn: Int64, tokensOut: Int64)] = [:]
        for usage in usages {
            let existing = models[usage.model] ?? .init(in: 0, out: 0, calls: 0)
            models[usage.model] = SyncPayload.ModelCounts(
                in: existing.in + usage.tokensIn,
                out: existing.out + usage.tokensOut,
                calls: existing.calls + usage.calls
            )
            platformModels[usage.platform, default: [:]][usage.model] = SyncPayload.ModelCounts(
                in: usage.tokensIn, out: usage.tokensOut, calls: usage.calls
            )
            let totals = platformTokens[usage.platform] ?? (0, 0)
            platformTokens[usage.platform] = (
                totals.tokensIn + usage.tokensIn,
                totals.tokensOut + usage.tokensOut
            )
        }
        var platforms: [String: SyncPayload.PlatformCounts] = [:]
        for (name, counts) in platformTokens {
            platforms[name] = .init(
                tokensIn: counts.tokensIn,
                tokensOut: counts.tokensOut,
                models: platformModels[name] ?? [:]
            )
        }
        let platform = ModelPlatform.dominant(models: usages)

        return SyncPayload(
            platform: platform, totals: totals, pet: petSnapshot, best: best,
            models: models, platforms: platforms
        )
    }
}
