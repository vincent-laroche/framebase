# Phase 4 — Complete organization, search, trash, and recovery

**Status:** Active implementation plan (2026-08-10)
**Authority:** `docs/MASTER_ROADMAP.md` defines the product outcome. This plan fixes the implementation sequence, safety boundary, and exit evidence for Phase 4.

## Outcome

Framebase becomes a complete manual visual-library manager: a user can organize, find, export, protect, and recover assets without losing immutable originals or silently overwriting a cloud-backed catalog.

This phase builds on the Phase 3 local-first catalog. It does not introduce Finder File Provider, OCR, AI classification, semantic search, workflows, agent mutation, arbitrary image transformations, public delivery, or permanent deletion without a separately approved purge review.

## Entry guard

- Existing libraries migrate additively and reopen unchanged when they have no Phase 4 data.
- All user-facing mutations flow through domain repositories; SwiftUI/AppKit does not execute SQL, manipulate managed originals, or create a second state model.
- Logical moves/renames never change an `AssetID`, `storageKey`, or original bytes.
- Cloud parity is versioned through the same outbox/revision/idempotency protocol as Phase 3. Worker migration, secret, binding, and deployment actions remain separately approval-gated.
- The Hair Solutions folder/tag template is vocabulary only until an explicit, reviewable Apply Template operation exists.

## Data model and migration

Add an immutable v4 catalog migration and matching Worker migration:

| Entity | Responsibility |
| --- | --- |
| `tags` / `asset_tags` | Canonical lowercase `namespace:value` tag identity, per-library uniqueness, membership timestamps, and tag revision state. |
| `saved_searches` | Named rule JSON with a validated schema, sort, optional list columns, and revision. |
| `asset_trash` | Original folder, albums, tags, metadata/organization receipt, trashed timestamp, scheduled purge date, and restore state. |
| `export_receipts` | Manifest reference, asset IDs, content digests, destination-independent completion evidence, and timestamp. |
| `backup_manifests` | Immutable catalog/export manifest digest and drill result; no copy of private original bytes in SQLite. |

Asset queries gain a composable `AssetFilter`: filename/display name, logical folder path, normalized image/EXIF fields, date range, rating/favorite, tag, album, and trash state. All filtering is parameterized SQL with indexes on normalized lookup paths, tags, timestamps, and trash state.

## Work packages

### 1. Catalog and domain spine

- Add typed tags, saved-search rules, trash receipts, duplicate candidates, export/backup manifests, search query/filter models, and explicit validation errors.
- Extend the catalog migration, repositories, change notification, and local cloud-state persistence.
- Add transactional album create/rename/reorder/delete/membership and tag create/rename/delete/bulk membership operations.
- Add rename and move-to-folder asset mutations; ensure conflict-safe outbox entries are written after local commit.
- Add trash/restore that preserves originals and all organization metadata. Purge is proposal-only and cannot remove bytes.
- Add duplicate-candidate scans keyed only by verified checksum; no automatic merge or delete.
- Add manifest export and verification helpers. An export copies to a user-selected destination, hashes every output byte, writes a manifest, and never mutates managed storage.

### 2. Native manual-organization UI

- Source-list Albums section supports create, rename, reorder, delete confirmation, selection, and membership actions.
- Inspector and browser expose asset rename, Move To, tags, bulk tags, favorites, ratings, trash/restore, Reveal, Materialize, Copy/Export, and duplicate-candidate state.
- Add a native searchable browser: persistent search field, tokens/filters, saved-search actions, smart-collection sidebar rows, and a list mode with sortable, accessible columns.
- Add a reviewable Apply Hair Solutions Template sheet showing exact folder/tag actions and no mutations until the user confirms. It creates only initial folders; on-first-use nodes appear as available vocabulary.
- Add a trash destination with retention countdown and disabled-by-design purge control that points to a separately gated review surface.

### 3. Cloud and recovery parity

- Extend v1.1 API/OpenAPI with tags, saved searches, album lifecycle, rename/trash/restore, export/backup receipt metadata, and duplicate-candidate records.
- Extend bootstrap/change snapshots, D1 mutations, audit events, revision checks, conflicts, and `FramebaseSync` reconciliation/outbox handling.
- Preserve offline behavior: every supported operation commits locally first, queues idempotently, retries after restart, and retains explicit conflicts on stale remote data.
- Keep fixed image derivatives as the Phase 3 fail-closed route until a separately approved Cloudflare Images binding is made; Phase 4 does not force that billing decision.

### 4. Verification and release

- Domain/catalog tests: migration/reopen, tag uniqueness and bulk edits, search predicates/index paths, album lifecycle, trash/restore receipts, duplicate candidates, template proposal/application, export checksum manifests, and backup restore drills.
- Sync/Worker tests: idempotency, stale revisions, offline replay, bootstrap parity, tag/album/trash synchronization, no duplicate retry, secret and private-metadata redaction.
- Native/UI tests: keyboard/menu/toolbar discoverability, search/token behavior, list sorting, multi-selection bulk tags/move/trash, album lifecycle, restore, export destination handling, and confirmation gates.
- Performance tests: 100,000 catalog search/pagination/list-sort bounds; bounded selection aggregation; no full original decode for browsing/search.
- The development deployment and any migration must be explicitly approved before application. Verify no public bucket/custom domain/CORS route, unauthenticated protected requests are denied, fixtures contain no personal media, and costs remain bounded.

## Completion matrix

| Roadmap requirement | Required evidence |
| --- | --- |
| Album lifecycle and memberships | Local/UI + Worker/sync tests covering create, rename, reorder, delete, add/remove memberships, retry and conflicts. |
| Tags and bulk editing | Migration/reopen tests, inspector/browser multi-select test, namespace validation, sync parity. |
| Complete search and saved rules | Parameterized catalog tests for each filter, native search/list UI tests, 100k performance evidence. |
| Rename, Move To, export/reveal/materialize | Immutable-key tests, destination export checksums, UI flow evidence. |
| Trash, restore, retention/purge review | Transactional receipts, offline/sync parity, no-purge safety test, explicit review-only gate. |
| Duplicate candidates | Verified-checksum-only tests and no automatic mutation test. |
| Sidecar/manifests, backup/export and restore | Signed/hashed manifest test plus a documented restore drill reconstructing relationships and availability. |
| Safety and privacy | No original deletion without approval, no credentials/paths/image data in logs, protected live API evidence. |

## Deployment and approval boundary

Code, local migrations, local fixtures, and documentation are in scope for this phase. Applying a D1 migration, deploying `framebase-api-dev`, configuring Images, creating cloud resources, changing secrets, applying a template to a real library, exporting actual customer/private media, backup destinations, permanent purges, DNS, or production changes each require current, explicit approval.
