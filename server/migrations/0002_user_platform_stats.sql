CREATE TABLE user_platform_stats (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform TEXT NOT NULL,
  tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_out INTEGER NOT NULL DEFAULT 0,
  models_json TEXT NOT NULL DEFAULT '{}',
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, platform)
) WITHOUT ROWID;

-- Preserve the previous single-platform baseline. A later sync from a new
-- client replaces this inferred row with explicit per-platform counts.
INSERT INTO user_platform_stats (
  user_id, platform, tokens_in, tokens_out, models_json, updated_at
)
SELECT
  id, platform, tokens_in, tokens_out, models_json,
  COALESCE(last_sync_at, created_at)
FROM users;

CREATE INDEX idx_user_platform_tokens
ON user_platform_stats(platform, (tokens_in + tokens_out));

-- Older clients attributed every model to the user's dominant platform.
-- Repair unambiguous historical model buckets before explicit platform
-- baselines take over.
INSERT INTO model_stats (
  platform, model, tokens_in, tokens_out, calls, updated_at
)
SELECT
  'codex', model, tokens_in, tokens_out, calls, updated_at
FROM model_stats
WHERE platform <> 'codex'
  AND (
    lower(model) LIKE 'gpt-%'
    OR lower(model) LIKE 'codex-%'
    OR lower(model) GLOB 'o[0-9]*'
  )
ON CONFLICT(platform, model) DO UPDATE SET
  tokens_in = tokens_in + excluded.tokens_in,
  tokens_out = tokens_out + excluded.tokens_out,
  calls = calls + excluded.calls,
  updated_at = MAX(updated_at, excluded.updated_at);

DELETE FROM model_stats
WHERE platform <> 'codex'
  AND (
    lower(model) LIKE 'gpt-%'
    OR lower(model) LIKE 'codex-%'
    OR lower(model) GLOB 'o[0-9]*'
  );

INSERT INTO model_stats (
  platform, model, tokens_in, tokens_out, calls, updated_at
)
SELECT
  'claude-code', model, tokens_in, tokens_out, calls, updated_at
FROM model_stats
WHERE platform = 'codex'
  AND NOT (
    lower(model) LIKE 'gpt-%'
    OR lower(model) LIKE 'codex-%'
    OR lower(model) GLOB 'o[0-9]*'
  )
ON CONFLICT(platform, model) DO UPDATE SET
  tokens_in = tokens_in + excluded.tokens_in,
  tokens_out = tokens_out + excluded.tokens_out,
  calls = calls + excluded.calls,
  updated_at = MAX(updated_at, excluded.updated_at);

DELETE FROM model_stats
WHERE platform = 'codex'
  AND NOT (
    lower(model) LIKE 'gpt-%'
    OR lower(model) LIKE 'codex-%'
    OR lower(model) GLOB 'o[0-9]*'
  );
