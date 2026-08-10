CREATE TABLE IF NOT EXISTS device_enrollment_challenges (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    device_name TEXT NOT NULL,
    public_key TEXT NOT NULL,
    scopes TEXT NOT NULL,
    challenge TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS device_enrollment_challenges_expiry_idx
    ON device_enrollment_challenges(expires_at, used_at);
