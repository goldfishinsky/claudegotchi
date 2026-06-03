import Foundation
import GRDB

public struct ModelUsage: Codable, FetchableRecord, PersistableRecord, Equatable {
    public var model: String
    public var tokensIn: Int64
    public var tokensOut: Int64
    public var calls: Int64

    public init(model: String, tokensIn: Int64, tokensOut: Int64, calls: Int64) {
        self.model = model
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.calls = calls
    }

    public static let databaseTableName = "model_usage"

    enum CodingKeys: String, CodingKey {
        case model
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case calls
    }
}

public enum ModelUsageStore {
    public static func bump(model: String, tokensIn: Int, tokensOut: Int, in db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO model_usage (model, tokens_in, tokens_out, calls)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(model) DO UPDATE SET
              tokens_in = tokens_in + excluded.tokens_in,
              tokens_out = tokens_out + excluded.tokens_out,
              calls = calls + 1
            """, arguments: [model, tokensIn, tokensOut])
    }

    public static func all(in db: DatabaseQueue) throws -> [ModelUsage] {
        try db.read { conn in
            try ModelUsage.order(sql: "tokens_in + tokens_out DESC, model ASC").fetchAll(conn)
        }
    }
}
