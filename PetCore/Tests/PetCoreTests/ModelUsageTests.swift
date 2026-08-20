import XCTest
import GRDB
@testable import PetCore

final class ModelUsageTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "musage-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testBumpInsertsThenAccumulates() throws {
        try db.write { try ModelUsageStore.bump(model: "opus", tokensIn: 100, tokensOut: 50, in: $0) }
        try db.write { try ModelUsageStore.bump(model: "opus", tokensIn: 10, tokensOut: 5, in: $0) }
        let all = try ModelUsageStore.all(in: db)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0], ModelUsage(model: "opus", tokensIn: 110, tokensOut: 55, calls: 2))
    }

    func testAllSortedByTokensDesc() throws {
        try db.write { try ModelUsageStore.bump(model: "small", tokensIn: 1, tokensOut: 1, in: $0) }
        try db.write { try ModelUsageStore.bump(model: "big", tokensIn: 500, tokensOut: 500, in: $0) }
        let all = try ModelUsageStore.all(in: db)
        XCTAssertEqual(all.map(\.model), ["big", "small"])
    }

    func testSameModelCanBeTrackedSeparatelyByPlatform() throws {
        try db.write {
            try ModelUsageStore.bump(
                platform: ModelPlatform.claudeCode, model: "shared-model",
                tokensIn: 10, tokensOut: 2, in: $0
            )
            try ModelUsageStore.bump(
                platform: ModelPlatform.codex, model: "shared-model",
                tokensIn: 30, tokensOut: 4, in: $0
            )
        }
        let all = try ModelUsageStore.all(in: db)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.platform), [ModelPlatform.codex, ModelPlatform.claudeCode])
        XCTAssertEqual(all.map(\.model), ["shared-model", "shared-model"])
    }
}
