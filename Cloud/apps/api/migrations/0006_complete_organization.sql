PRAGMA foreign_keys = OFF;

ALTER TABLE albums ADD COLUMN sort_order REAL NOT NULL DEFAULT 0.0;
ALTER TABLE album_assets ADD COLUMN sort_order REAL NOT NULL DEFAULT 0.0;

CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
    revision INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS asset_tags (
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    added_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (asset_id, tag_id)
);
CREATE INDEX IF NOT EXISTS asset_tags_tag_asset_idx ON asset_tags(tag_id, asset_id);

CREATE TABLE IF NOT EXISTS saved_searches (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
    rules_json TEXT NOT NULL CHECK (json_valid(rules_json)),
    sort_json TEXT NOT NULL CHECK (json_valid(sort_json)),
    revision INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS asset_trash (
    asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    prior_folder_id TEXT NOT NULL,
    prior_album_ids_json TEXT NOT NULL CHECK (json_valid(prior_album_ids_json)),
    prior_tag_ids_json TEXT NOT NULL CHECK (json_valid(prior_tag_ids_json)),
    trashed_at TEXT NOT NULL DEFAULT (datetime('now')),
    scheduled_purge_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS asset_trash_scheduled_purge_idx ON asset_trash(scheduled_purge_at);

CREATE TABLE IF NOT EXISTS export_receipts (
    id TEXT PRIMARY KEY,
    manifest_sha256 TEXT NOT NULL,
    asset_ids_json TEXT NOT NULL CHECK (json_valid(asset_ids_json)),
    completed_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS backup_manifests (
    id TEXT PRIMARY KEY,
    manifest_sha256 TEXT NOT NULL,
    recorded_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_restore_drill_at TEXT,
    last_restore_drill_result TEXT,
    revision INTEGER NOT NULL DEFAULT 0
);

ALTER TABLE change_events RENAME TO change_events_phase3;
DROP INDEX IF EXISTS change_events_revision_idx;

CREATE TABLE change_events (
    revision INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK (entity_type IN (
        'asset', 'folder', 'album', 'blob', 'tag', 'saved_search',
        'export_receipt', 'backup_manifest'
    )),
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL,
    payload TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    client_mutation_id TEXT UNIQUE,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO change_events (revision, entity_type, entity_id, operation, payload, actor_id, client_mutation_id, created_at)
SELECT revision, entity_type, entity_id, operation, payload, actor_id, client_mutation_id, created_at
FROM change_events_phase3;

DROP TABLE change_events_phase3;
CREATE INDEX change_events_revision_idx ON change_events(revision);

PRAGMA foreign_keys = ON;
