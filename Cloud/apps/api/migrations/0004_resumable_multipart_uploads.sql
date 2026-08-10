CREATE TABLE IF NOT EXISTS multipart_uploads (
    id TEXT PRIMARY KEY,
    blob_sha256 TEXT NOT NULL REFERENCES blobs(sha256) ON DELETE CASCADE,
    r2_key TEXT NOT NULL,
    r2_upload_id TEXT NOT NULL,
    device_id TEXT NOT NULL REFERENCES devices(id),
    media_type TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    part_byte_size INTEGER NOT NULL,
    part_count INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'aborted', 'expired')),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at TEXT,
    UNIQUE (blob_sha256, status)
);

CREATE TABLE IF NOT EXISTS multipart_upload_parts (
    upload_id TEXT NOT NULL REFERENCES multipart_uploads(id) ON DELETE CASCADE,
    part_number INTEGER NOT NULL,
    etag TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (upload_id, part_number)
);

CREATE INDEX IF NOT EXISTS multipart_uploads_active_blob_idx
    ON multipart_uploads(blob_sha256, status, updated_at);
