CREATE TABLE oauth_grants (
  grant_hash TEXT PRIMARY KEY,
  code_challenge TEXT NOT NULL,
  github_id INTEGER NOT NULL,
  github_login TEXT NOT NULL,
  avatar_url TEXT,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX idx_oauth_grants_expires_at ON oauth_grants(expires_at);
