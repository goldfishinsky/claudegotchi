CREATE TABLE users (
  id                INTEGER PRIMARY KEY,      -- GitHub user id（天然稳定，省一个索引）
  login             TEXT NOT NULL,
  avatar_url        TEXT,
  platform          TEXT NOT NULL DEFAULT 'claude-code',
  hidden            INTEGER NOT NULL DEFAULT 0,
  token_hash        TEXT,                     -- API token 的 sha256（无 sessions 表）
  token_created_at  INTEGER,
  -- 终身总量（绝对值、只增）
  tokens_in INTEGER NOT NULL DEFAULT 0, tokens_out INTEGER NOT NULL DEFAULT 0,
  sessions  INTEGER NOT NULL DEFAULT 0, tools_used INTEGER NOT NULL DEFAULT 0,
  -- 现役宠物快照（无存活宠物时为 NULL）
  pet_uid TEXT, pet_species TEXT, pet_name TEXT,
  pet_birthday INTEGER, pet_xp INTEGER NOT NULL DEFAULT 0,
  -- 历史最佳（服务端取 max 保留）
  best_survival_ms INTEGER NOT NULL DEFAULT 0, best_pet_species TEXT, best_pet_name TEXT,
  -- 按模型终身总量 JSON（同时是服务端算增量的基线）
  models_json TEXT NOT NULL DEFAULT '{}',
  flagged INTEGER NOT NULL DEFAULT 0, flag_note TEXT,
  created_at INTEGER NOT NULL, last_sync_at INTEGER
);
CREATE INDEX idx_users_tokens  ON users(platform, (tokens_in + tokens_out));
CREATE INDEX idx_users_best    ON users(platform, best_survival_ms);
CREATE INDEX idx_users_current ON users(platform, pet_birthday) WHERE pet_birthday IS NOT NULL;
CREATE UNIQUE INDEX idx_users_token_hash ON users(token_hash) WHERE token_hash IS NOT NULL;

CREATE TABLE model_stats (
  platform TEXT NOT NULL, model TEXT NOT NULL,
  tokens_in INTEGER NOT NULL DEFAULT 0, tokens_out INTEGER NOT NULL DEFAULT 0,
  calls INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL,
  PRIMARY KEY (platform, model)
) WITHOUT ROWID;
