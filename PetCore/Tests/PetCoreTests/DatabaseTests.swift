import XCTest
import GRDB
@testable import PetCore

final class DatabaseTests: XCTestCase {
    func testFreshDatabaseHasAllTables() throws {
        let dbPath = NSTemporaryDirectory() + "test-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let db = try Database.open(at: dbPath)
        let tables = try db.read { try $0.tableNames() }

        XCTAssertTrue(tables.contains("pet"))
        XCTAssertTrue(tables.contains("event"))
        XCTAssertTrue(tables.contains("daily_rollup"))
    }

    func testUniqueAlivePartialIndex() throws {
        let dbPath = NSTemporaryDirectory() + "test-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let db = try Database.open(at: dbPath)
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO pet (species, birthday, fullness, stamina, intimacy, xp, last_tick_at)
                VALUES ('frog', 0, 100, 100, 50, 0, 0)
                """)
        }
        XCTAssertThrowsError(
            try db.write { conn in
                try conn.execute(sql: """
                    INSERT INTO pet (species, birthday, fullness, stamina, intimacy, xp, last_tick_at)
                    VALUES ('cat', 0, 100, 100, 50, 0, 0)
                    """)
            },
            "Inserting a second alive pet must violate the partial unique index"
        )
    }

    func testStatRangeCheckConstraint() throws {
        let dbPath = NSTemporaryDirectory() + "test-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let db = try Database.open(at: dbPath)
        XCTAssertThrowsError(
            try db.write { conn in
                try conn.execute(sql: """
                    INSERT INTO pet (species, birthday, fullness, stamina, intimacy, xp, last_tick_at)
                    VALUES ('frog', 0, 150, 100, 50, 0, 0)
                    """)
            },
            "Fullness > 100 must violate CHECK constraint"
        )
    }

    func testV2TablesExist() throws {
        let dbPath = NSTemporaryDirectory() + "test-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        let tables = try db.read { try $0.tableNames() }
        XCTAssertTrue(tables.contains("watched_repo"))
        XCTAssertTrue(tables.contains("watched_author"))
        XCTAssertTrue(tables.contains("pr"))
        XCTAssertTrue(tables.contains("fix_job"))
    }

    func testV2AddsTypedEventColumns() throws {
        let dbPath = NSTemporaryDirectory() + "test-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        let cols = try db.read {
            try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('event')")
        }
        XCTAssertTrue(cols.contains("session_id"))
        XCTAssertTrue(cols.contains("cwd"))
    }

    func testMigrationIsIdempotent() throws {
        let dbPath = NSTemporaryDirectory() + "test-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        _ = try Database.open(at: dbPath)
        let db2 = try Database.open(at: dbPath)
        let tables = try db2.read { try $0.tableNames() }
        XCTAssertTrue(tables.contains("pr"))
    }

    private func petColumns(_ db: DatabaseQueue) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('pet')") }
    }

    func testV3AddsLastEventAtColumn() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        XCTAssertTrue(try petColumns(db).contains("last_event_at"))
    }

    func testV3CreatesModelUsageTable() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        let tables = try db.read { try $0.tableNames() }
        XCTAssertTrue(tables.contains("model_usage"))
    }

    func testV3MigrationIdempotentAcrossReopen() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        _ = try Database.open(at: dbPath)
        let db2 = try Database.open(at: dbPath)
        let tables = try db2.read { try $0.tableNames() }
        XCTAssertTrue(tables.contains("model_usage"))
        XCTAssertEqual(try petColumns(db2).filter { $0 == "last_event_at" }.count, 1)
    }

    func testV4AddsUidColumn() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        XCTAssertTrue(try petColumns(db).contains("uid"))
    }

    func testV4BackfillsUidOnExistingRows() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let queue = try DatabaseQueue(path: dbPath)
        try Database.migrator.migrate(queue, upTo: "v3_pet_stats")
        try queue.write { conn in
            try conn.execute(sql: """
                INSERT INTO pet (species, birthday, fullness, stamina, intimacy, xp, last_tick_at, last_event_at)
                VALUES ('frog', 1000, 100, 100, 50, 0, 1000, 1000)
                """)
        }
        XCTAssertFalse(try petColumns(queue).contains("uid"), "uid absent before v4")

        try Database.migrator.migrate(queue)

        let uid = try queue.read { try String.fetchOne($0, sql: "SELECT uid FROM pet") }
        XCTAssertNotNil(uid, "existing row backfilled with a uid")
        XCTAssertEqual(uid?.count, 26, "backfilled uid is a 26-char ULID")
    }

    func testHatchedPetHasUid() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        let pet = try HatchService.ensureAlive(db, nowMs: 1000)
        XCTAssertEqual(pet.uid?.count, 26)
    }
}

extension GRDB.Database {
    func tableNames() throws -> [String] {
        try String.fetchAll(self, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    }
}
