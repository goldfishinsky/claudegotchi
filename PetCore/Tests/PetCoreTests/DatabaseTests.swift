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
}

extension GRDB.Database {
    func tableNames() throws -> [String] {
        try String.fetchAll(self, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    }
}
