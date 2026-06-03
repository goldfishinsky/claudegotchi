import XCTest
import GRDB
@testable import PetCore

final class FixJobTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "fixjob-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    // MARK: - FixJobMachine.next (pure transition graph)

    func testQueuedAdvancesToCheckout() {
        XCTAssertEqual(FixJobMachine.next(.queued, exit: nil, canceled: false), .checkout)
    }

    func testCheckoutAdvancesToRunning() {
        XCTAssertEqual(FixJobMachine.next(.checkout, exit: nil, canceled: false), .running)
    }

    func testRunningWithZeroExitSucceeds() {
        XCTAssertEqual(FixJobMachine.next(.running, exit: 0, canceled: false), .succeeded)
    }

    func testRunningWithNonzeroExitFails() {
        XCTAssertEqual(FixJobMachine.next(.running, exit: 1, canceled: false), .failed)
    }

    func testRunningWithoutExitStaysRunning() {
        XCTAssertEqual(FixJobMachine.next(.running, exit: nil, canceled: false), .running)
    }

    func testCanceledOverridesAnyState() {
        XCTAssertEqual(FixJobMachine.next(.queued, exit: nil, canceled: true), .canceled)
        XCTAssertEqual(FixJobMachine.next(.checkout, exit: nil, canceled: true), .canceled)
        XCTAssertEqual(FixJobMachine.next(.running, exit: 0, canceled: true), .canceled)
    }

    func testTerminalStatesAreFixpoints() {
        for s: FixJobState in [.succeeded, .failed, .canceled] {
            XCTAssertEqual(FixJobMachine.next(s, exit: 0, canceled: false), s)
            XCTAssertEqual(FixJobMachine.next(s, exit: 1, canceled: true), s)
        }
    }

    // MARK: - FixJobMachine.canStart (pure guards)

    func testCanStartRequiresAllPreconditions() {
        XCTAssertTrue(FixJobMachine.canStart(prIsMine: true, localPathValid: true, hasActiveJob: false))
    }

    func testCannotStartWhenNotMine() {
        XCTAssertFalse(FixJobMachine.canStart(prIsMine: false, localPathValid: true, hasActiveJob: false))
    }

    func testCannotStartWhenPathInvalid() {
        XCTAssertFalse(FixJobMachine.canStart(prIsMine: true, localPathValid: false, hasActiveJob: false))
    }

    func testCannotStartWhenJobActive() {
        XCTAssertFalse(FixJobMachine.canStart(prIsMine: true, localPathValid: true, hasActiveJob: true))
    }

    // MARK: - FixJobStore DAO

    private func makePR(in db: DatabaseQueue) throws -> Int64 {
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO pr (repo_slug, number, title, author, state, is_draft,
                                review_decision, unresolved_count, last_approved_review_at,
                                head_branch, url, updated_at, is_mine, fetched_at)
                VALUES ('o/r', 7, 't', 'me', 'OPEN', 0, 'CHANGES_REQUESTED', 1, 0,
                        'feature', 'https://x', 0, 1, 0)
                """)
            return conn.lastInsertedRowID
        }
    }

    func testInsertAndFetchJob() throws {
        let prId = try makePR(in: db)
        var job = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .queued, createdAt: 100)
        try db.write { conn in try job.insert(conn) }
        XCTAssertNotNil(job.id)
        let fetched = try db.read { try FixJobStore.job(id: job.id!, in: $0) }
        XCTAssertEqual(fetched?.state, .queued)
        XCTAssertEqual(fetched?.prNumber, 7)
    }

    func testMarkCheckoutPersistsWorktreeAndStart() throws {
        let prId = try makePR(in: db)
        var job = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .queued, createdAt: 100)
        try db.write { conn in try job.insert(conn) }
        try db.write { conn in
            try FixJobStore.markCheckout(id: job.id!, worktreePath: "/wt/o/r/7", startedAt: 150, in: conn)
        }
        let fetched = try db.read { try FixJobStore.job(id: job.id!, in: $0) }!
        XCTAssertEqual(fetched.state, .checkout)
        XCTAssertEqual(fetched.worktreePath, "/wt/o/r/7")
        XCTAssertEqual(fetched.startedAt, 150)
    }

    func testSetPromptRoundTrips() throws {
        let prId = try makePR(in: db)
        var job = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .checkout, createdAt: 100)
        try db.write { conn in try job.insert(conn) }
        try db.write { conn in
            try FixJobStore.setPrompt(id: job.id!, prompt: "fix the off-by-one", in: conn)
        }
        let fetched = try db.read { try FixJobStore.job(id: job.id!, in: $0) }!
        XCTAssertEqual(fetched.prompt, "fix the off-by-one")
    }

    func testMarkRunningPersistsLogPath() throws {
        let prId = try makePR(in: db)
        var job = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .checkout, createdAt: 100)
        try db.write { conn in try job.insert(conn) }
        try db.write { conn in
            try FixJobStore.markRunning(id: job.id!, logPath: "/wt/o/r/7/fix.log", in: conn)
        }
        let fetched = try db.read { try FixJobStore.job(id: job.id!, in: $0) }!
        XCTAssertEqual(fetched.state, .running)
        XCTAssertEqual(fetched.logPath, "/wt/o/r/7/fix.log")
    }

    func testFinishPersistsTerminalStateAndOutcome() throws {
        let prId = try makePR(in: db)
        var job = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .running, createdAt: 100)
        try db.write { conn in try job.insert(conn) }
        try db.write { conn in
            try FixJobStore.finish(id: job.id!, state: .succeeded, exitCode: 0,
                                   commitSha: "abc", logPath: "/l", error: nil,
                                   endedAt: 200, in: conn)
        }
        let fetched = try db.read { try FixJobStore.job(id: job.id!, in: $0) }!
        XCTAssertEqual(fetched.state, .succeeded)
        XCTAssertEqual(fetched.exitCode, 0)
        XCTAssertEqual(fetched.commitSha, "abc")
        XCTAssertEqual(fetched.endedAt, 200)
    }

    func testHistoryOrderedCreatedAtDescWithLimit() throws {
        let prId = try makePR(in: db)
        try db.write { conn in
            for ts in [10, 30, 20] as [Int64] {
                var j = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .succeeded, createdAt: ts)
                try j.insert(conn)
            }
        }
        let rows = try db.read { try FixJobStore.history(limit: 2, in: $0) }
        XCTAssertEqual(rows.map(\.createdAt), [30, 20])
    }

    func testActiveJobLookupFindsRunningOrCheckout() throws {
        let prId = try makePR(in: db)
        try db.write { conn in
            var a = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .succeeded, createdAt: 1)
            try a.insert(conn)
            var b = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .running, createdAt: 2)
            try b.insert(conn)
        }
        let active = try db.read { try FixJobStore.activeJob(repoSlug: "o/r", in: $0) }
        XCTAssertEqual(active?.state, .running)
        let none = try db.read { try FixJobStore.activeJob(repoSlug: "other/x", in: $0) }
        XCTAssertNil(none)
    }

    func testUnfinishedJobsForReconciliation() throws {
        let prId = try makePR(in: db)
        try db.write { conn in
            var a = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .running, createdAt: 1)
            try a.insert(conn)
            var b = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .checkout, createdAt: 2)
            try b.insert(conn)
            var c = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .queued, createdAt: 3)
            try c.insert(conn)
            var d = FixJob(prRowid: prId, repoSlug: "o/r", prNumber: 7, state: .succeeded, createdAt: 4)
            try d.insert(conn)
        }
        let inFlight = try db.read { try FixJobStore.inFlightJobs(in: $0) }
        XCTAssertEqual(Set(inFlight.map(\.state)), [.running, .checkout])
        let queued = try db.read { try FixJobStore.queuedJobs(in: $0) }
        XCTAssertEqual(queued.map(\.state), [.queued])
    }
}
