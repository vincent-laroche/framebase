# Phase 5 — Finder File Provider Integration

## Authority and entry gate

This phase implements the Finder integration described in
`docs/MASTER_ROADMAP.md`. It may begin only after the isolated macOS CI job has
passed the native Phase 4 UI suite and Vincent explicitly approves creation of
the File Provider extension target, App Group, signing configuration, and
Keychain access-group changes.

Before implementation, record the approved values for:

- production and development bundle identifiers;
- App Group identifier and ownership;
- signing team/certificate/profile approach;
- Keychain sharing access group and migration/rollback plan;
- target library/device, if any materialization smoke test is proposed.

No real library must be mounted or migrated during this gate. R2 credentials
never enter the host app or extension bundle. Device credentials remain the
short-lived, scoped API credentials already owned by the credential store.

## Goal

Expose the existing logical Framebase catalog as a reliable private Finder
location and standard open-panel source. File Provider operations must use the
same catalog/domain rules as the app and materialize immutable bytes only on
demand.

## Sequenced implementation

### 1. Signed lifecycle spike

Create a minimal `NSFileProviderReplicatedExtension` target with an approved
App Group and Keychain-sharing configuration. Prove extension registration,
domain add/remove, app/extension shared-container access, and clean host-app
relaunch in a disposable development domain. Do not enumerate a real library
or implement mutations in this step.

### 2. Shared File Provider contracts

Add a package-level adapter boundary for File Provider item identity, version,
and error mapping. Stable `FolderID` and `AssetID` values map one-to-one to
item identifiers; catalog storage keys and R2 keys never become Finder paths.
The extension reads through domain protocols and must not execute catalog SQL
or managed-file mutations directly.

### 3. Enumeration and anchors

Implement root/folder enumeration and durable change anchors against a
disposable catalog fixture. Anchor advancement, invalidation, pagination, and
restart behavior require deterministic tests. Finder display names and logical
folder paths come from catalog state; original bytes are not fetched for an
enumeration.

### 4. Checksum-verified materialization

Add an authenticated materializer that downloads one requested original to a
private shared cache using a unique temporary file, verifies expected checksum
and byte size, then atomically publishes it. It rejects unavailable/expired
credentials, mismatches, path traversal, and duplicate writers. Failed or
cancelled downloads remove only their own temporary files. No cache result is
reported available before verification succeeds.

### 5. Finder mutations through the common pipeline

Map Finder rename, logical move, folder creation, trash, restore, and import
requests to the existing domain use cases. The extension cannot bypass folder
cycle checks, trash receipts, asset immutability, sync outbox, authorization,
or audit rules. Permanent purge remains unavailable. Every accepted Finder
mutation returns an idempotent, typed result and the app observes it through
the same catalog state.

### 6. Offline, eviction, and conflict behavior

Add explicit pinned/offline metadata and bounded cache eviction without
touching immutable originals. Define deterministic Finder errors for
unavailable remote originals, conflicts, expired credentials, and retryable
network failures. Expose the same activity/failure state in the host app.

## Tests and exit evidence

- Package tests cover ID mapping, anchor durability, pagination, error mapping,
  checksum failures, cancellation cleanup, eviction, and common-pipeline
  mutations using temporary fixture catalogs and fake authenticated transport.
- Native File Provider tests run only on the isolated macOS CI runner or a
  dedicated disposable session, never on an active development desktop.
- A cloud-only fixture original opens through a standard macOS client and its
  materialized checksum/byte size match the verified Blob evidence.
- Finder rename/move/trash/restore update Framebase logical state without
  moving R2 bytes or local managed originals.
- Repeated enumeration, host-app relaunch, eviction, offline operation, and
  a conflict response leave catalog identity and recoverability intact.
- The final verification records the approved signing/App Group values without
  exposing credentials and includes a tested rollback that removes the
  disposable File Provider domain without damaging the local library.

## Explicit non-goals

- No real-library migration or retention change.
- No public sharing, permanent public URLs, or embedded R2 credentials.
- No semantic intelligence, workflows, CLI/MCP expansion, or permanent purge.
- No Finder operation that bypasses a domain protocol or emits an unreviewed
  destructive mutation.
