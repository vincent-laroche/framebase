PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS library_metadata (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT OR IGNORE INTO library_metadata (id) VALUES ('framebase-dev-library');

CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    device_name TEXT NOT NULL,
    public_key TEXT NOT NULL,
    scopes TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS blobs (
    id TEXT PRIMARY KEY,
    sha256 TEXT UNIQUE NOT NULL,
    byte_size INTEGER NOT NULL CHECK (byte_size > 0),
    media_type TEXT NOT NULL,
    original_extension TEXT NOT NULL,
    r2_key TEXT UNIQUE NOT NULL,
    upload_state TEXT NOT NULL DEFAULT 'pending' CHECK (upload_state IN ('pending', 'verified', 'abandoned')),
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS folders (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id TEXT REFERENCES folders(id),
    system_kind TEXT,
    sort_order REAL NOT NULL DEFAULT 0.0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL DEFAULT 0
);

INSERT OR IGNORE INTO folders (id, name, system_kind, revision)
VALUES ('system-inbox', 'Inbox', 'inbox', 0);

CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    blob_id TEXT NOT NULL REFERENCES blobs(id),
    display_name TEXT NOT NULL,
    folder_id TEXT NOT NULL REFERENCES folders(id),
    favorite INTEGER NOT NULL DEFAULT 0 CHECK (favorite IN (0, 1)),
    rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'trashed')),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS albums (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS album_assets (
    album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    added_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (album_id, asset_id)
);

CREATE TABLE IF NOT EXISTS change_events (
    revision INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('asset', 'folder', 'album', 'blob')),
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL,
    payload TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    client_mutation_id TEXT UNIQUE,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS idempotency_keys (
    client_mutation_id TEXT PRIMARY KEY,
    actor_id TEXT NOT NULL,
    response_code INTEGER NOT NULL,
    response_body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS audit_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_mutation_id TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    before_state TEXT,
    after_state TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS change_events_revision_idx ON change_events(revision);
CREATE INDEX IF NOT EXISTS assets_folder_idx ON assets(folder_id);
CREATE INDEX IF NOT EXISTS blobs_upload_state_idx ON blobs(upload_state);
