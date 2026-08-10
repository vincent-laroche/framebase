ALTER TABLE idempotency_keys ADD COLUMN request_fingerprint TEXT NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS mutation_guards (
    request_id TEXT PRIMARY KEY,
    valid INTEGER NOT NULL CHECK (valid = 1)
);
