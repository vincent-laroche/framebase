-- Monotonic Change Log for Sync
CREATE TABLE IF NOT EXISTS change_events (
    revision INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL,
    payload TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    client_mutation_id TEXT UNIQUE,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Registered Devices
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    device_name TEXT NOT NULL,
    public_key TEXT NOT NULL,
    scopes TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    revoked_at TEXT
);

-- Content-Addressed Blobs
CREATE TABLE IF NOT EXISTS blobs (
    id TEXT PRIMARY KEY,
    sha256 TEXT UNIQUE NOT NULL,
    byte_size INTEGER NOT NULL,
    media_type TEXT NOT NULL,
    original_extension TEXT NOT NULL,
    r2_key TEXT NOT NULL,
    upload_state TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Logical Folders
CREATE TABLE IF NOT EXISTS folders (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id TEXT REFERENCES folders(id),
    system_kind TEXT,
    sort_order REAL NOT NULL DEFAULT 0.0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL
);

-- Logical Assets
CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    blob_id TEXT NOT NULL REFERENCES blobs(id),
    display_name TEXT NOT NULL,
    folder_id TEXT NOT NULL REFERENCES folders(id),
    favorite INTEGER NOT NULL DEFAULT 0,
    rating INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL
);

-- Albums & Membership
CREATE TABLE IF NOT EXISTS albums (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS album_assets (
    album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    added_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (album_id, asset_id)
);

-- Idempotency Receipts
CREATE TABLE IF NOT EXISTS idempotency_keys (
    client_mutation_id TEXT PRIMARY KEY,
    actor_id TEXT NOT NULL,
    response_code INTEGER NOT NULL,
    response_body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Reversible Mutation Audit Trail
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
