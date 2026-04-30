import Foundation
import GRDB

public enum Database {
    public static func open(at path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        try migrator.migrate(queue)
        return queue
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial_schema") { db in
            try db.execute(sql: """
                CREATE TABLE pet (
                  id INTEGER PRIMARY KEY,
                  species TEXT NOT NULL,
                  name TEXT,
                  birthday INTEGER NOT NULL,
                  death_at INTEGER,
                  fullness REAL NOT NULL CHECK (fullness BETWEEN 0 AND 100),
                  stamina REAL NOT NULL CHECK (stamina BETWEEN 0 AND 100),
                  intimacy REAL NOT NULL CHECK (intimacy BETWEEN 0 AND 100),
                  xp INTEGER NOT NULL CHECK (xp >= 0),
                  last_tick_at INTEGER NOT NULL,
                  last_applied_event_id INTEGER NOT NULL DEFAULT 0,
                  hibernation_since INTEGER,
                  death_window_state TEXT NOT NULL DEFAULT '[]'
                );
                """)
            // SQLite treats every NULL as distinct in unique indexes, so
            // indexing `death_at` directly does NOT enforce singleton-alive
            // (two rows with death_at = NULL would not collide). Index the
            // expression `(death_at IS NULL)` instead — it evaluates to 1
            // for every alive row, so all alive rows collide on the same
            // indexed value and the UNIQUE constraint fires.
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_one_alive
                ON pet((death_at IS NULL)) WHERE death_at IS NULL;
                """)
            try db.execute(sql: """
                CREATE TABLE event (
                  id INTEGER PRIMARY KEY,
                  helper_event_id TEXT NOT NULL UNIQUE,
                  ts INTEGER NOT NULL,
                  type TEXT NOT NULL,
                  pet_id INTEGER NOT NULL REFERENCES pet(id),
                  payload TEXT
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_event_ts ON event(ts);")
            try db.execute(sql: "CREATE INDEX idx_event_pet ON event(pet_id);")
            try db.execute(sql: """
                CREATE TABLE daily_rollup (
                  date TEXT PRIMARY KEY,
                  sessions INTEGER NOT NULL,
                  messages INTEGER NOT NULL,
                  tokens_in INTEGER NOT NULL DEFAULT 0,
                  tokens_out INTEGER NOT NULL DEFAULT 0,
                  tools_used INTEGER NOT NULL
                );
                """)
        }
        return m
    }
}
