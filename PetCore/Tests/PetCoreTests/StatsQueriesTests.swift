import XCTest
import GRDB
@testable import PetCore

final class StatsQueriesTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!
    let utc = TimeZone(identifier: "UTC")!
    // 2026-06-03T12:00:00Z
    let nowMs: Int64 = 1_780_488_000_000

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "stats-\(UUID()).sqlite"
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

    func testLifetimeTokens() throws {
        try seedRollup("2026-06-01", tokensIn: 100, tokensOut: 200)
        try seedRollup("2026-06-02", tokensIn: 10, tokensOut: 5)
        XCTAssertEqual(try StatsQueries.lifetimeTokens(db), 315)
    }

    func testTodayTotalsZeroRow() throws {
        let t = try StatsQueries.todayTotals(db, nowMs: nowMs, tz: utc)
        XCTAssertEqual(t, TodayTotals(tokens: 0, sessions: 0, tools: 0))
    }

    func testTodayTotalsPopulated() throws {
        try seedRollup("2026-06-03", sessions: 2, tools: 4, tokensIn: 30, tokensOut: 70)
        let t = try StatsQueries.todayTotals(db, nowMs: nowMs, tz: utc)
        XCTAssertEqual(t, TodayTotals(tokens: 100, sessions: 2, tools: 4))
    }

    func testActiveStreakWithGap() throws {
        // today + yesterday present; gap on 06-01 → streak = 2.
        try seedRollup("2026-06-03", sessions: 1)
        try seedRollup("2026-06-02", sessions: 1)
        try seedRollup("2026-05-31", sessions: 1)
        XCTAssertEqual(try StatsQueries.activeStreakDays(db, nowMs: nowMs, tz: utc), 2)
    }

    func testActiveStreakZeroWhenTodayMissing() throws {
        try seedRollup("2026-06-02", sessions: 1)
        XCTAssertEqual(try StatsQueries.activeStreakDays(db, nowMs: nowMs, tz: utc), 0)
    }

    func testPeakDayTokens() throws {
        try seedRollup("2026-06-01", tokensIn: 100, tokensOut: 100) // 200
        try seedRollup("2026-06-02", tokensIn: 500, tokensOut: 1)   // 501
        XCTAssertEqual(try StatsQueries.peakDayTokens(db), 501)
    }

    func testHeatmapSeriesLengthAndKnownDay() throws {
        try seedRollup("2026-06-03", tokensIn: 1, tokensOut: 2)
        let series = try StatsQueries.heatmapSeries(db, weeks: 2, nowMs: nowMs, tz: utc)
        XCTAssertEqual(series.count, 14)
        XCTAssertEqual(series.last?.day, "2026-06-03")
        XCTAssertEqual(series.last?.tokens, 3)
        XCTAssertTrue(series.dropLast().allSatisfy { $0.tokens == 0 }, "absent days are zero, not missing")
    }

    func testModelUsage() throws {
        try db.write { try ModelUsageStore.bump(model: "opus", tokensIn: 5, tokensOut: 5, in: $0) }
        XCTAssertEqual(try StatsQueries.modelUsage(db).map(\.model), ["opus"])
    }

    func testPetAgeDays() throws {
        let born = nowMs - 3 * 86_400_000
        _ = try Pet.insert(.fresh(species: "frog", at: born), into: db)
        XCTAssertEqual(try StatsQueries.petAgeDays(db, nowMs: nowMs), 3)
    }

    func testGrowthHistoryNewestFirst() throws {
        let dead1 = try Pet.insert(.fresh(species: "frog", at: 1000), into: db)
        try Pet.markDead(id: dead1.id!, at: 2000, in: db)
        let dead2 = try Pet.insert(.fresh(species: "cat", at: 3000), into: db)
        try Pet.markDead(id: dead2.id!, at: 4000, in: db)
        let hist = try StatsQueries.growthHistory(db, limit: 10)
        XCTAssertEqual(hist.map(\.species), ["cat", "frog"], "newest death first")
        XCTAssertEqual(hist.first?.diedMs, 4000)
    }

    func testGrowthHistoryHonorsLimitBeyondInlineCap() throws {
        // 25 dead pets; a limit above the inline cap (20) must return all of them
        // so the view can drive its own 查看全部 affordance instead of the SQL LIMIT.
        for i in 1...25 {
            let p = try Pet.insert(.fresh(species: "frog", at: Int64(i) * 1000), into: db)
            try Pet.markDead(id: p.id!, at: Int64(i) * 1000 + 500, in: db)
        }
        XCTAssertEqual(try StatsQueries.growthHistory(db, limit: 20).count, 20)
        XCTAssertEqual(try StatsQueries.growthHistory(db, limit: 500).count, 25)
    }
}
