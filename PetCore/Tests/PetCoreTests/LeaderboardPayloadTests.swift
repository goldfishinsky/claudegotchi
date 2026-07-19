import XCTest
import GRDB
@testable import PetCore

final class LeaderboardPayloadTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!
    // 2026-06-03T12:00:00Z
    let nowMs: Int64 = 1_780_488_000_000
    let day: Int64 = 86_400_000

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "lbpayload-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func seedRollup(_ date: String, sessions: Int = 0, tools: Int = 0,
                            tokensIn: Int = 0, tokensOut: Int = 0) throws {
        try db.write {
            try $0.execute(sql: """
                INSERT INTO daily_rollup (date, sessions, messages, tokens_in, tokens_out, tools_used)
                VALUES (?, ?, 0, ?, ?, ?)
                """, arguments: [date, sessions, tokensIn, tokensOut, tools])
        }
    }

    func testEmptyDbReturnsNil() throws {
        XCTAssertNil(try LeaderboardPayload.build(db: db, nowMs: nowMs))
    }

    func testAlivePetSnapshotWithNilName() throws {
        let born = nowMs - 10 * day
        _ = try Pet.insert(.fresh(species: "frog", at: born, uid: "01ALIVEUID"), into: db)
        let payload = try XCTUnwrap(try LeaderboardPayload.build(db: db, nowMs: nowMs))
        XCTAssertEqual(payload.platform, "claude-code")
        XCTAssertEqual(payload.pet?.uid, "01ALIVEUID")
        XCTAssertEqual(payload.pet?.species, "frog")
        XCTAssertNil(payload.pet?.name)
        XCTAssertEqual(payload.pet?.birthdayMs, born)
        XCTAssertEqual(payload.pet?.xp, 0)
        XCTAssertEqual(payload.best?.survivalMs, 10 * day)
        XCTAssertEqual(payload.best?.species, "frog")
    }

    func testNoAlivePetGivesNullPetButStillBuilds() throws {
        let dead = try Pet.insert(.fresh(species: "slime", at: 0), into: db)
        try Pet.markDead(id: dead.id!, at: 7 * day, in: db)
        let payload = try XCTUnwrap(try LeaderboardPayload.build(db: db, nowMs: nowMs))
        XCTAssertNil(payload.pet)
        XCTAssertEqual(payload.best?.survivalMs, 7 * day)
        XCTAssertEqual(payload.best?.species, "slime")
    }

    func testDeadHistoryBestBeatsCurrent() throws {
        let dead = try Pet.insert(.fresh(species: "cat", at: 0), into: db)
        try Pet.markDead(id: dead.id!, at: 30 * day, in: db)
        var alive = try Pet.insert(.fresh(species: "frog", at: nowMs - 5 * day), into: db)
        alive.name = "Kero"
        try Pet.update(alive, in: db)
        let payload = try XCTUnwrap(try LeaderboardPayload.build(db: db, nowMs: nowMs))
        XCTAssertEqual(payload.pet?.name, "Kero")
        XCTAssertEqual(payload.best?.survivalMs, 30 * day, "dead 30d beats live 5d")
        XCTAssertEqual(payload.best?.species, "cat")
    }

    func testCurrentBeatsDead() throws {
        let dead = try Pet.insert(.fresh(species: "cat", at: 0), into: db)
        try Pet.markDead(id: dead.id!, at: 2 * day, in: db)
        _ = try Pet.insert(.fresh(species: "frog", at: nowMs - 40 * day), into: db)
        let payload = try XCTUnwrap(try LeaderboardPayload.build(db: db, nowMs: nowMs))
        XCTAssertEqual(payload.best?.survivalMs, 40 * day, "live 40d beats dead 2d")
        XCTAssertEqual(payload.best?.species, "frog")
    }

    func testTotalsSplitAndModels() throws {
        _ = try Pet.insert(.fresh(species: "frog", at: nowMs - day), into: db)
        try seedRollup("2026-06-01", sessions: 2, tools: 5, tokensIn: 100, tokensOut: 40)
        try seedRollup("2026-06-02", sessions: 3, tools: 7, tokensIn: 10, tokensOut: 8)
        try db.write { try ModelUsageStore.bump(model: "claude-sonnet-4-5", tokensIn: 60, tokensOut: 30, in: $0) }
        try db.write { try ModelUsageStore.bump(model: "claude-sonnet-4-5", tokensIn: 40, tokensOut: 10, in: $0) }
        try db.write { try ModelUsageStore.bump(model: "claude-opus-4-1", tokensIn: 5, tokensOut: 2, in: $0) }

        let payload = try XCTUnwrap(try LeaderboardPayload.build(db: db, nowMs: nowMs))
        XCTAssertEqual(payload.totals.tokensIn, 110)
        XCTAssertEqual(payload.totals.tokensOut, 48)
        XCTAssertEqual(payload.totals.sessions, 5)
        XCTAssertEqual(payload.totals.toolsUsed, 12)
        XCTAssertEqual(payload.models.count, 2)
        XCTAssertEqual(payload.models["claude-sonnet-4-5"], SyncPayload.ModelCounts(in: 100, out: 40, calls: 2))
        XCTAssertEqual(payload.models["claude-opus-4-1"], SyncPayload.ModelCounts(in: 5, out: 2, calls: 1))
    }

    func testDominantPlatformIsCodexWhenCodexTokensLead() throws {
        _ = try Pet.insert(.fresh(species: "frog", at: nowMs - day), into: db)
        try db.write { try ModelUsageStore.bump(model: "gpt-5-codex", tokensIn: 300, tokensOut: 50, in: $0) }
        try db.write { try ModelUsageStore.bump(model: "claude-sonnet-4-5", tokensIn: 60, tokensOut: 30, in: $0) }
        let payload = try XCTUnwrap(try LeaderboardPayload.build(db: db, nowMs: nowMs))
        XCTAssertEqual(payload.platform, "codex")
    }

    func testDominantPlatformTieResolvesToClaudeCode() throws {
        _ = try Pet.insert(.fresh(species: "frog", at: nowMs - day), into: db)
        try db.write { try ModelUsageStore.bump(model: "gpt-5-codex", tokensIn: 50, tokensOut: 0, in: $0) }
        try db.write { try ModelUsageStore.bump(model: "claude-opus-4-1", tokensIn: 50, tokensOut: 0, in: $0) }
        let payload = try XCTUnwrap(try LeaderboardPayload.build(db: db, nowMs: nowMs))
        XCTAssertEqual(payload.platform, "claude-code")
    }
}
