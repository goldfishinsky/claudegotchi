import Foundation
import GRDB

public enum Database {
    public static func open(at path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        try migrator.migrate(queue)
        return queue
    }

    static var migrator: DatabaseMigrator {
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
        m.registerMigration("v2_pr_watch") { db in
            try db.execute(sql: """
                CREATE TABLE watched_repo (
                  id INTEGER PRIMARY KEY,
                  slug TEXT NOT NULL UNIQUE,
                  local_path TEXT,
                  enabled INTEGER NOT NULL DEFAULT 1
                );
                """)
            try db.execute(sql: """
                CREATE TABLE watched_author (
                  id INTEGER PRIMARY KEY,
                  repo_id INTEGER NOT NULL REFERENCES watched_repo(id) ON DELETE CASCADE,
                  login TEXT NOT NULL,
                  UNIQUE (repo_id, login)
                );
                """)
            try db.execute(sql: """
                CREATE TABLE pr (
                  id INTEGER PRIMARY KEY,
                  repo_slug TEXT NOT NULL,
                  number INTEGER NOT NULL,
                  title TEXT NOT NULL,
                  author TEXT NOT NULL,
                  state TEXT NOT NULL,
                  is_draft INTEGER NOT NULL DEFAULT 0,
                  review_decision TEXT,
                  unresolved_count INTEGER NOT NULL DEFAULT 0,
                  last_approved_review_at INTEGER NOT NULL DEFAULT 0,
                  head_branch TEXT NOT NULL,
                  url TEXT NOT NULL,
                  updated_at INTEGER NOT NULL,
                  is_mine INTEGER NOT NULL DEFAULT 0,
                  fetched_at INTEGER NOT NULL,
                  UNIQUE (repo_slug, number)
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_pr_repo ON pr(repo_slug);")
            try db.execute(sql: """
                CREATE TABLE fix_job (
                  id INTEGER PRIMARY KEY,
                  pr_rowid INTEGER NOT NULL REFERENCES pr(id),
                  repo_slug TEXT NOT NULL,
                  pr_number INTEGER NOT NULL,
                  state TEXT NOT NULL,
                  prompt TEXT,
                  worktree_path TEXT,
                  started_at INTEGER,
                  ended_at INTEGER,
                  exit_code INTEGER,
                  error TEXT,
                  log_path TEXT,
                  commit_sha TEXT,
                  created_at INTEGER NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_fix_job_pr ON fix_job(pr_rowid);")
            try db.execute(sql: "CREATE INDEX idx_fix_job_state ON fix_job(state);")
            try db.execute(sql: "ALTER TABLE event ADD COLUMN session_id TEXT;")
            try db.execute(sql: "ALTER TABLE event ADD COLUMN cwd TEXT;")
            try db.execute(sql: "CREATE INDEX idx_event_session ON event(session_id);")
        }
        m.registerMigration("v3_pet_stats") { db in
            try db.execute(sql: "ALTER TABLE pet ADD COLUMN last_event_at INTEGER NOT NULL DEFAULT 0;")
            try db.execute(sql: """
                CREATE TABLE model_usage (
                  model TEXT PRIMARY KEY,
                  tokens_in INTEGER NOT NULL DEFAULT 0,
                  tokens_out INTEGER NOT NULL DEFAULT 0,
                  calls INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
        m.registerMigration("v4_leaderboard") { db in
            try db.execute(sql: "ALTER TABLE pet ADD COLUMN uid TEXT;")
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM pet WHERE uid IS NULL")
            for id in ids {
                try db.execute(sql: "UPDATE pet SET uid = ? WHERE id = ?", arguments: [ULID.generate(), id])
            }
        }
        m.registerMigration("v5_stamina_charge_marker") { db in
            try db.execute(sql: "ALTER TABLE pet ADD COLUMN last_stamina_charge_at INTEGER;")
        }
        m.registerMigration("v6_genome") { db in
            try db.execute(sql: "ALTER TABLE pet ADD COLUMN genome INTEGER;")
            let availableIDs = PixelSpeciesCatalog.ids
            let rows = try Row.fetchAll(db, sql: "SELECT id, uid, species FROM pet WHERE genome IS NULL")
            for row in rows {
                let id: Int64 = row["id"]
                let uid: String? = row["uid"]
                let species: String = row["species"]
                let start = PetGenomeBackfill.startingSeed(uid: uid, fallback: id)
                guard let seed = PetGenomeBackfill.findSeed(
                    startingFrom: start, targetSpecies: species, availableIDs: availableIDs
                ) else { continue }
                try db.execute(sql: "UPDATE pet SET genome = ? WHERE id = ?", arguments: [Genome.pack(seed), id])
            }
        }
        m.registerMigration("v7_model_usage_platform") { db in
            try db.execute(sql: "ALTER TABLE model_usage RENAME TO model_usage_v6;")
            try db.execute(sql: """
                CREATE TABLE model_usage (
                  platform TEXT NOT NULL,
                  model TEXT NOT NULL,
                  tokens_in INTEGER NOT NULL DEFAULT 0,
                  tokens_out INTEGER NOT NULL DEFAULT 0,
                  calls INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (platform, model)
                ) WITHOUT ROWID;
                """)
            try db.execute(sql: """
                INSERT INTO model_usage (platform, model, tokens_in, tokens_out, calls)
                SELECT
                  CASE
                    WHEN lower(model) LIKE 'gpt-%'
                      OR lower(model) LIKE 'codex-%'
                      OR lower(model) GLOB 'o[0-9]*'
                    THEN 'codex'
                    ELSE 'claude-code'
                  END,
                  model, tokens_in, tokens_out, calls
                FROM model_usage_v6;
                """)
            try db.execute(sql: "DROP TABLE model_usage_v6;")
        }
        return m
    }
}
