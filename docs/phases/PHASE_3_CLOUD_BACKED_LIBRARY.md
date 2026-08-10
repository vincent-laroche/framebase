# Phase 3 — Cloud-backed library and offline sync

**Status:** Active implementation plan (2026-08-09)
**Authority:** `docs/MASTER_ROADMAP.md` governs the product outcome. This plan governs the Phase 3 protocol, local migration, implementation order, and exit evidence.

## Outcome and boundary

Phase 3 makes one Mac library optionally cloud-backed without weakening the Phase 1 local-library guarantee. The catalog remains locally queryable and browsable when offline. Existing managed originals remain immutable and local until each remote blob has been uploaded and verified; no Phase 3 operation deletes, moves, or replaces a local original.

The phase delivers four coherent capabilities:

1. A typed `FramebaseAPIClient` for the frozen v1 HTTP contract and its Phase 3 extensions.
2. Device keypair enrollment, persisted only in Keychain/Secure Enclave where available, with short-lived session renewal and no Cloudflare/R2 credential in the app.
3. A durable local cloud-state database: blob identity, migration manifest, outbox, sync cursor, remote revision map, conflicts, and diagnostics.
4. A `FramebaseSync` actor that inventories, uploads, verifies, applies/replays changes, resumes after interruption, and leaves the UI responsive from local SQLite.

Phase 3 remains a development-only cloud release until its exit gate passes. It does not migrate the existing personal library, alter production/DNS/public R2 access, introduce File Provider, AI, workflows, or arbitrary image transformations.

## Locked protocol decisions

### Local catalog migration

`assets.id` and `assets.storage_key` are immutable Phase 1 identifiers. New local tables add rather than rewrite cloud state:

- `cloud_blobs`: SHA-256, byte size, content type, extension, remote blob ID, verification state.
- `asset_cloud_state`: one asset-to-blob relation, materialization state, remote revision, and last error.
- `sync_outbox`: stable idempotency key, request JSON, retry count, next attempt, and terminal state.
- `sync_state`: per-library enrollment, cursor/watermark, mode, and last successful sync.
- `sync_conflicts`: retained local/remote payloads and explicit resolution state.
- `migration_manifest`: snapshot of every source asset and immutable original at migration start.

The migration is additive and replayable. A library can return to local-only by disabling cloud mode; neither local rows nor original bytes are removed.

### Device enrollment

The app creates an EC signing key in Secure Enclave where available, otherwise a Keychain-backed software key explicitly labelled as development fallback. The private key never leaves the device. A user-approved pairing credential may bootstrap one device, but is not persisted in the app, source tree, or library. The Worker issues a single-use challenge; the app signs the canonical challenge payload; the Worker verifies that signature before issuing the short-lived session.

### Upload and verification

The client hashes files off the main actor, creates immutable blob records by SHA-256, and resumes transfers from durable state. Small originals use a bounded direct upload. Larger or retry-prone originals use a resumable multipart session whose authoritative uploaded-part state is durable on the private Worker and can be re-read by a restarted client; abandoned remote sessions can be explicitly cleaned up. A blob is not considered cloud-verified until byte size and checksum are confirmed through the remote contract and the client has performed a deterministic verification read. Local originals always remain available.

### Sync and conflicts

Every supported local cloud mutation is committed to the local catalog and appended to the outbox before network work begins. The sync actor sends idempotent batches, advances its cursor only after durable local application, and treats a revision mismatch as a retained conflict rather than silently choosing a side. The UI reports sync status and unresolved conflict count but never blocks browsing/importing on a network request. Folder lifecycle and post-migration import synchronization are explicit remaining implementation gates, not implied by the current asset-edit path.

### Image delivery

Phase 3 exposes only a fixed thumbnail and preview vocabulary (`grid-256`, `grid-512`, `preview-1600`). The client never asks the Worker for arbitrary dimensions. Phase 1 ImageIO rendering continues to use local derivatives while a local original exists; remote materialization/download is on-demand and verified before any decode.

## Work packages and ownership

| Package | Deliverables | Verification |
| --- | --- | --- |
| 0. Entry guard | Local/remote inventory, dev-only resource confirmation, test fixtures, migration design | No personal media or production surface touched |
| 1. Local spine | Domain cloud models, catalog v2 migration, manifest/outbox/cursor/conflict persistence | Migration/reopen/rollback tests |
| 2. Secure transport | API client, device key store, pairing/challenge enrollment, session storage | URLProtocol contract tests; no credential serialization |
| 3. Transfer plane | Hashing, direct and multipart resumable upload, verification, cancellation/cleanup | Interrupted upload and byte mismatch tests |
| 4. Sync plane | Outbox pump, change consumer, reconciliation, conflict retention, diagnostics | Offline/retry/idempotency/rebuild tests |
| 5. App integration | Explicit opt-in, sync status/conflict UI, on-demand remote materialization | Native UI build/test; browsing remains local-first |
| 6. Dev release | Worker migration/API deployment and 5,000-asset fixture proof | Approved dev-only live run, cost/privacy/rollback evidence |

The primary agent owns shared contracts, project configuration, Worker/client protocol, app integration, and all Git/documentation work.

## Migration sequence

1. Open the local catalog and produce a read-only immutable manifest.
2. Hash originals in bounded background work and associate local assets to `cloud_blobs` without changing their IDs or storage keys.
3. Enroll the device and persist only key references/session metadata.
4. Create remote Blob and Asset records through idempotent outbox operations.
5. Upload missing blobs, resumably where necessary; verify each object before marking it cloud-verified.
6. Consume the change feed into a clean fixture catalog and compare asset, folder, album, metadata, relationship, revision, size, and digest parity.
7. Enable cloud-backed mode only after parity succeeds; preserve local originals indefinitely pending a separate retention approval.

## Required Phase 3 Worker changes

- Add challenge/complete enrollment routes, public-key verification, session refresh, and device revoke by authenticated device or operator pairing credential.
- Add immutable blob metadata to bootstrap/change payloads and predictable conflict responses.
- Add bounded multipart initiate/part/complete/abort lifecycle and expired-session cleanup, while preserving the private R2-only model.
- Add fixed authenticated derivative routes/variant validation; no arbitrary transform parameters or public delivery path.
- Version the OpenAPI contract as v1.1 without breaking Phase 2 fixture clients.

All Worker secret, migration, and development deployment changes remain explicitly approval-gated by `AGENTS.md`; no production, DNS, Access, public bucket, or personal-library action is implied by this plan.

## Exit gate

Phase 3 is complete only when the evidence below is recorded in `PROJECT.md`:

1. A 5,000-asset non-personal fixture library enrolls, migrates, resumes across interruption, and retains byte/count/folder/album/metadata/revision parity.
2. Offline mutations later synchronize or persist visible, explicit conflicts; no operation duplicates after retry/restart.
3. The grid and inspector remain local-derivative first; remote-only materialization is on-demand and checksum-verified.
4. No failure deletes the only verified copy; disabling cloud mode restores local-only operation without catalog corruption.
5. API, catalog, transfer, sync, native app, and 5,000-asset tests cover normal, network-loss, stale-revision, cancellation, checksum, and credential-redaction paths.
6. The approved development deployment passes the fixture migration/rebuild proof, remains private, has bounded cost/variants, and retains no personal media.
