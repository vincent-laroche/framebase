# Phase 2 — Cloud Foundation Implementation Plan

## Document Authority & Scope

This document is the official implementation plan for **Phase 2 — Cloud Contract and Safety Spine** of Framebase, as required by `docs/MASTER_ROADMAP.md`.

- **Goal:** Establish a secure, isolated Cloudflare-backed development environment (`framebase-api-dev`, `framebase-catalog-dev`, `framebase-blobs-dev`) and API contract, allowing registered development devices to authenticate, upload fixture assets, verify checksums, download originals privately, and synchronize catalog mutations via a versioned change feed.
- **Scope Boundary:** Phase 2 uses **development resources and fixture assets only**. Personal photos, production deployments, and production DNS changes remain strictly out of scope until explicitly approved in a later phase.

---

## 1. Cloudflare Inventory (Read-Only)

A read-only capability check was performed on 2026-08-09.

### Account & Credentials State
- `CLOUDFLARE_ACCOUNT_ID`: Present in `/Users/vMac/.env`.
- `CLOUDFLARE_MASTER_ACCOUNT_API_TOKEN`: Active account-level API access verified.

### Resource Inventory
- **D1 Databases:** `hsc-media-bridge-audit`, `email-marketing-control-plane`, `sync-state`.
- **R2 Buckets:** `hsc-immich-pikapod-backup`, `hsc-media-origin`, `hsc-temporary-exports`.
- **Framebase Resources:** **Zero** existing Framebase cloud resources.

> [!IMPORTANT]
> All Framebase Cloudflare resources created in Phase 2 will carry explicit `-dev` suffixes and operate in isolated development environments.

---

## 2. Resource Isolation & Naming Strategy

| Resource Type | Resource Name | Access / Privacy Policy |
|---|---|---|
| Cloudflare Worker | `framebase-api-dev` | Isolated TypeScript Hono worker on `*.workers.dev` (or internal route) |
| Cloudflare D1 | `framebase-catalog-dev` | Private SQL database instance |
| Cloudflare R2 | `framebase-blobs-dev` | **Private** bucket. No public custom domain, no public bucket URL. |

---

## 3. Threat Model & Device Authentication

### Scopes & Authorization
Framebase is single-user but enforces strict API authorization scopes:
- `library.read`: Read catalog entities and change feed.
- `assets.import`: Initiate blob upload and create assets.
- `assets.metadata.write`: Update asset metadata, ratings, favorites.
- `assets.organize`: Move, rename, reparent folders and assets.
- `originals.download`: Request authenticated download capabilities for originals.
- `trash.write`: Move assets/folders to trash.
- `purge.approve`: **Excluded** from all device default scopes in Phase 2.

### Enrollment & Token Exchange
1. **Device Identity:** Each Mac or CLI agent registers a `Device` record (`id`, `device_name`, `public_key_pem`, `scopes`, `status`).
2. **Challenge Exchange:** Client signs a server challenge with its local keypair (stored in Keychain).
3. **Session Bearer Token:** Server returns a short-lived (1-hour) signed JWT / bearer token.

---

## 4. D1 Schema & Migrations (`migrations/d1/0001_initial_schema.sql`)

```sql
-- Monotonic Change Log for Sync
CREATE TABLE change_events (
    revision INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL, -- 'asset', 'folder', 'album', 'blob'
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL,   -- 'create', 'update', 'delete'
    payload TEXT NOT NULL,     -- JSON compact representation
    actor_id TEXT NOT NULL,
    client_mutation_id TEXT UNIQUE,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Registered Devices
CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    device_name TEXT NOT NULL,
    public_key TEXT NOT NULL,
    scopes TEXT NOT NULL,      -- JSON array of allowed scopes
    status TEXT NOT NULL DEFAULT 'active', -- 'active', 'revoked'
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    revoked_at TEXT
);

-- Content-Addressed Blobs
CREATE TABLE blobs (
    id TEXT PRIMARY KEY,       -- SHA-256 hex string
    sha256 TEXT UNIQUE NOT NULL,
    byte_size INTEGER NOT NULL,
    media_type TEXT NOT NULL,
    original_extension TEXT NOT NULL,
    r2_key TEXT NOT NULL,
    upload_state TEXT NOT NULL DEFAULT 'pending', -- 'pending', 'verified', 'abandoned'
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Logical Folders
CREATE TABLE folders (
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
CREATE TABLE assets (
    id TEXT PRIMARY KEY,
    blob_id TEXT NOT NULL REFERENCES blobs(id),
    display_name TEXT NOT NULL,
    folder_id TEXT NOT NULL REFERENCES folders(id),
    favorite INTEGER NOT NULL DEFAULT 0,
    rating INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'active', -- 'active', 'trashed'
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL
);

-- Albums & Membership
CREATE TABLE albums (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    revision INTEGER NOT NULL
);

CREATE TABLE album_assets (
    album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    added_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (album_id, asset_id)
);

-- Idempotency Receipts
CREATE TABLE idempotency_keys (
    client_mutation_id TEXT PRIMARY KEY,
    actor_id TEXT NOT NULL,
    response_code INTEGER NOT NULL,
    response_body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Reversible Mutation Audit Trail
CREATE TABLE audit_events (
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
```

---

## 5. Blob Key & Storage Design

### Key Structure
Original binaries are stored in Cloudflare R2 using content-addressed keys:

```text
blobs/sha256/{hash_prefix_2}/{full_sha256}.{ext}
```

Example: `blobs/sha256/e3/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.jpg`

### Upload Verification Pipeline
1. Client hashes file locally (SHA-256) and requests `POST /v1/blobs/upload-initiate`.
2. Worker returns a short-lived presigned R2 upload URL (valid for 15 minutes) with explicit `Content-Type` and `checksum-sha256` headers.
3. Client uploads directly to R2.
4. Client calls `POST /v1/blobs/upload-complete` with ETag and byte size.
5. Worker verifies R2 object header/metadata and marks blob status as `verified` in D1.

---

## 6. API Endpoint Catalog

All endpoints require `Authorization: Bearer <token>` and operate under `/v1`.

| Endpoint | Method | Scope | Description |
|---|---|---|---|
| `/v1/health` | `GET` | Public | System status, D1 health, version info |
| `/v1/auth/enroll` | `POST` | Public | Device enrollment and token exchange |
| `/v1/changes` | `GET` | `library.read` | Monotonic change feed (`?after={revision}&limit={n}`) |
| `/v1/blobs/upload-initiate` | `POST` | `assets.import` | Request presigned upload URL |
| `/v1/blobs/upload-complete` | `POST` | `assets.import` | Confirm R2 upload and verify |
| `/v1/blobs/:id/download` | `GET` | `originals.download` | Request presigned download URL |
| `/v1/mutations` | `POST` | Various | Batch domain catalog mutations (requires `Idempotency-Key`) |

---

## 7. Swift Architecture Extensions

Add two new packages under `Packages/FramebaseKit/Sources/`:

```text
Packages/FramebaseKit/Sources/
├── FramebaseDomain/
├── FramebaseCatalog/
├── FramebaseMedia/
├── FramebaseAPIClient/    # NEW: HTTP/REST client for /v1 Worker endpoints
└── FramebaseSync/         # NEW: Local outbox, sync cursor, change consumer
```

---

## 8. Verification Matrix

| Gate | Target | Assertion |
|---|---|---|
| **Contract Tests** | TypeScript API (`Cloud/apps/api`) | 100% of endpoints pass Hono test suite |
| **Idempotency** | D1 API | Duplicate `Idempotency-Key` returns exact cached response without re-executing SQL |
| **Checksum Integrity** | R2 + D1 | Mismatched SHA-256 or truncated byte count rejects upload completion |
| **Change Feed** | D1 Change Log | Monotonic revisions match exact state rebuild |
| **Negative Auth** | Authentication Middleware | Missing or invalid bearer token returns HTTP 401 |
| **Local App Integrity** | SwiftPM & Xcode UI Tests | All existing 32 package tests and 5 UI tests pass without regression |

---

## Proposed File Changes Strategy

```text
[NEW] Cloud/apps/api/package.json
[NEW] Cloud/apps/api/wrangler.json
[NEW] Cloud/apps/api/src/index.ts
[NEW] Cloud/apps/api/src/db/schema.sql
[NEW] Cloud/apps/api/src/routes/health.ts
[NEW] Cloud/apps/api/src/routes/auth.ts
[NEW] Cloud/apps/api/src/routes/blobs.ts
[NEW] Cloud/apps/api/src/routes/changes.ts
[NEW] Cloud/apps/api/src/routes/mutations.ts
[NEW] Packages/FramebaseKit/Sources/FramebaseAPIClient/
[NEW] Packages/FramebaseKit/Sources/FramebaseSync/
[NEW] docs/phases/PHASE_2_CLOUD_FOUNDATION.md
```
