import Foundation
import GRDB

public struct ModelUsage: Codable, FetchableRecord, PersistableRecord, Equatable {
    public var platform: String
    public var model: String
    public var tokensIn: Int64
    public var tokensOut: Int64
    public var calls: Int64

    public init(platform: String, model: String, tokensIn: Int64, tokensOut: Int64, calls: Int64) {
        self.platform = platform
        self.model = model
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.calls = calls
    }

    public init(model: String, tokensIn: Int64, tokensOut: Int64, calls: Int64) {
        self.init(
            platform: ModelPlatform.infer(model: model),
            model: model,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            calls: calls
        )
    }

    public static let databaseTableName = "model_usage"

    enum CodingKeys: String, CodingKey {
        case platform
        case model
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case calls
    }
}

public enum ModelUsageStore {
    public static func bump(
        platform: String, model: String, tokensIn: Int, tokensOut: Int, in db: GRDB.Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO model_usage (platform, model, tokens_in, tokens_out, calls)
            VALUES (?, ?, ?, ?, 1)
            ON CONFLICT(platform, model) DO UPDATE SET
              tokens_in = tokens_in + excluded.tokens_in,
              tokens_out = tokens_out + excluded.tokens_out,
              calls = calls + 1
            """, arguments: [platform, model, tokensIn, tokensOut])
    }

    public static func bump(model: String, tokensIn: Int, tokensOut: Int, in db: GRDB.Database) throws {
        try bump(
            platform: ModelPlatform.infer(model: model),
            model: model,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            in: db
        )
    }

    public static func all(in db: DatabaseQueue) throws -> [ModelUsage] {
        try db.read { conn in
            try ModelUsage.order(sql: "tokens_in + tokens_out DESC, platform ASC, model ASC").fetchAll(conn)
        }
    }
}
