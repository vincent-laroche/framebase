-- Phase 8 remote adapter foundation. These tables hold only public identity
-- metadata and one-way credential/token hashes; raw credentials never persist.
CREATE TABLE IF NOT EXISTS agent_identities (
    id TEXT PRIMARY KEY,
    owner_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    scopes_json TEXT NOT NULL CHECK (json_valid(scopes_json)),
    credential_hash TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS agent_identities_owner_idx ON agent_identities(owner_device_id, status);

CREATE TABLE IF NOT EXISTS agent_operations (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL REFERENCES agent_identities(id) ON DELETE RESTRICT,
    kind TEXT NOT NULL CHECK (kind IN ('addTags')),
    status TEXT NOT NULL CHECK (status IN ('proposed', 'approved', 'succeeded', 'stale', 'expired', 'failed')),
    target_asset_ids_json TEXT NOT NULL CHECK (json_valid(target_asset_ids_json)),
    apply_asset_ids_json TEXT NOT NULL CHECK (json_valid(apply_asset_ids_json)),
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
    tag_revision INTEGER NOT NULL,
    catalog_revision INTEGER NOT NULL,
    snapshot_sha256 TEXT NOT NULL,
    approval_token_hash TEXT,
    approval_expires_at TEXT,
    applied_mutation_id TEXT UNIQUE,
    result_json TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS agent_operations_agent_idx ON agent_operations(agent_id, created_at DESC);
CREATE INDEX IF NOT EXISTS agent_operations_status_idx ON agent_operations(status, approval_expires_at);

CREATE TABLE IF NOT EXISTS agent_operation_audit_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL REFERENCES agent_identities(id) ON DELETE RESTRICT,
    operation_id TEXT REFERENCES agent_operations(id) ON DELETE RESTRICT,
    actor_id TEXT NOT NULL,
    event_type TEXT NOT NULL CHECK (event_type IN ('identity_created', 'identity_revoked', 'proposal_created', 'approval_issued', 'applied', 'stale', 'expired', 'failed')),
    details_json TEXT NOT NULL CHECK (json_valid(details_json)),
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS agent_operation_audit_events_operation_idx ON agent_operation_audit_events(operation_id, id);
