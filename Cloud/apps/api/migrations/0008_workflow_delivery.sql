-- Phase 7 source-only delivery outbox. This migration is intentionally not
-- applied or bound to a Queue until a separate development deployment approval.
-- Queue messages contain only opaque operation and dispatch identifiers; all
-- targets, catalog state, approvals, and results stay in D1.
CREATE TABLE IF NOT EXISTS workflow_delivery_dispatches (
    id TEXT PRIMARY KEY,
    operation_id TEXT NOT NULL UNIQUE REFERENCES agent_operations(id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('waiting_approval', 'pending', 'dispatching', 'queued', 'succeeded', 'stale', 'dead_lettered')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    max_attempts INTEGER NOT NULL DEFAULT 3 CHECK (max_attempts BETWEEN 1 AND 10),
    last_error_code TEXT,
    last_error_summary TEXT,
    queued_at TEXT,
    completed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS workflow_delivery_dispatches_status_idx ON workflow_delivery_dispatches(status, created_at);

CREATE TABLE IF NOT EXISTS workflow_delivery_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    dispatch_id TEXT NOT NULL REFERENCES workflow_delivery_dispatches(id) ON DELETE RESTRICT,
    event_type TEXT NOT NULL CHECK (event_type IN ('created', 'approval_paused', 'approval_resumed', 'enqueued', 'duplicate_ignored', 'attempt_started', 'retry_scheduled', 'succeeded', 'stale', 'dead_lettered', 'recovered')),
    attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
    details_json TEXT NOT NULL CHECK (json_valid(details_json)),
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS workflow_delivery_events_dispatch_idx ON workflow_delivery_events(dispatch_id, id);
