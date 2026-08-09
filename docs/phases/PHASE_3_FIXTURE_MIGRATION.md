# Phase 3.1 — Fixture-Only Cloud Migration Gate

## Authority and decision

This is the focused entry plan for the first Phase 3 implementation slice. It
implements a **fixture-only** copy-and-verify migration path. Vincent selected
this path on 2026-08-09 instead of authorizing a controlled migration of the
real library.

It does not authorize a scan, copy, upload, hash, catalog mutation, or setting
change for `~/Pictures/Framebase Library.framebase` or any other personal
library. It also does not authorize Cloudflare resource creation, deployment,
DNS changes, secret changes, or public delivery.

`docs/MASTER_ROADMAP.md` remains the product authority. This document narrows
only the first Phase 3.1 gate; it does not claim the whole Phase 3 exit gate.
The executable task breakdown is
[`docs/superpowers/plans/2026-08-09-fixture-library-migration.md`](../superpowers/plans/2026-08-09-fixture-library-migration.md).

## Goal

Prove that Framebase can take a synthetic, managed fixture library through a
restartable local manifest, idempotent remote blob/asset registration,
copy-and-verify upload, and clean-catalog parity comparison while preserving
every local source byte.

The proof must use isolated temporary fixture directories and the existing
development Worker contract only through explicit, opt-in manual verification.
All committed tests run against fakes; no test enrolls a live device or makes a
network request.

## Starting facts discovered from the implemented Phase 2 surface

- Local `Asset.storageKey` is an immutable UUID/shard path and is one-to-one
  with the current local `assets` table. There is no local `Blob` or
  `AssetBlob` table yet.
- The Worker has a `blobs` table and content-addressed R2 keys, but its current
  blob routes do not compare uploaded bytes to the declared SHA-256 or byte
  size. Its direct-upload endpoint accepts a caller-provided R2 key.
- The Worker has logical `folders` and `assets` tables, but the current
  mutation route only emits change events and audit records; it does not write
  those canonical entity rows. It also has no asset-registration API.
- Existing `FramebaseCatalogSync` covers folder/rating/favorite/move metadata
  events only. It is not a valid original-byte migration pipeline.

These gaps are preconditions for migration, not implementation details to
work around.

## Scope

1. Harden the existing development Worker blob contract and make its canonical
   folder/asset rows truthful.
2. Add an authenticated, idempotent asset-registration contract that preserves
   the local Asset UUID while referencing a verified content-addressed Blob.
3. Add local Blob and AssetBlob persistence with stable Asset IDs and explicit
   migration states.
4. Add a dedicated, actor-isolated fixture migration coordinator with a durable
   manifest, checksum evidence, retry/cancel handling, and no delete path.
5. Add a deterministic 5,000-asset fixture acceptance suite, including crash
   resume, failed upload retry, byte parity, and clean-catalog parity.

## Explicit non-goals

- Migrating a real or user-selected library, including the existing 1,602-asset
  personal library.
- Enabling, changing, or relying on the app's Cloud (Dev) enrollment or Library
  Sync toggle.
- Deleting, evicting, renaming, or relocating local originals; setting
  `original_available` to false; retention policy; remote-only materialization.
- Multipart uploads, Cloudflare R2 Local Uploads, Cloudflare Images variants,
  File Provider, offline conflict UI, albums/album memberships, and public
  asset URLs. These remain later Phase 3 work.
- Any `wrangler deploy`, remote D1/R2 write, secret operation, or Cloudflare
  resource operation. A later manual fixture smoke test is separate and needs
  an explicit go-ahead when it is ready.

## Design contract

### Safety invariant

The coordinator is copy-and-verify only:

```text
read local original -> hash -> register/upload/verify remote copy -> record evidence
                                                            |
                                                            +-- never delete or alter local original
```

It must never call `AssetBlobStore.removeNewlyCommitted`, `FileManager.removeItem`,
or `CatalogDatabase.setOriginalAvailable(false)` for a migration. A failed,
cancelled, or restarted run leaves the managed original and its existing
`Asset.storageKey` untouched.

### Remote canonical model

The remote `Blob` is content-addressed by lowercase SHA-256. A remote `Asset`
keeps the existing local Asset UUID and references that Blob. Folder UUIDs are
also preserved. Server-side writes must update the D1 entity tables and append
one canonical change event in the same logical operation; a change log alone
is not canonical state.

### Local model

The existing `assets` rows retain their identity and immutable `storage_key`.
The Phase 3 catalog migration adds:

- `blobs`: immutable checksum/size/type/extension evidence and upload state;
- `asset_blobs`: current Asset-to-Blob reference without changing `AssetID`;
- migration-state rows in a separate `Sync/migration.sqlite` database so an
  interrupted run resumes without turning sync bookkeeping into catalog domain
  state.

The coordinator accepts an injected fixture authorization and fixture root. It
rejects any input not created by the deterministic fixture factory. It is not
wired into `AppContainer` in this slice.

### Proof levels

| Level | Runs in CI/local tests | Can touch real Cloudflare dev data |
| --- | --- | --- |
| Contract and coordinator tests | Yes, fakes only | No |
| 5,000-asset acceptance | Yes, temporary fixture library + fake remote | No |
| Manual development smoke test | No, separate written approval | Only disposable fixtures |

## Entry gate

Before implementation begins:

- Current package and UI suites are green.
- `git status` is reviewed; the existing uncommitted Cloud Settings work is
  preserved and not folded into this migration slice.
- The test design proves that no fixture helper accepts an arbitrary external
  library URL.

## Completion gate for this slice

- A 5,000-asset deterministic fixture library completes a full migration with
  no changed local original bytes, no changed local storage keys, and no Asset
  UUID changes.
- Every remote verified blob has the same SHA-256 and byte size as its local
  source; every migrated asset references a verified blob.
- Stopping after any manifest state and restarting resumes without duplicate
  blob or asset creation.
- A fault-injected upload failure is retryable and records its error; a
  cancellation records an incomplete state without cleanup of local originals.
- A clean fixture catalog rebuilt from canonical remote records has identical
  asset IDs, folder relationships, display names, ratings, favorites, and
  checksum-to-asset associations.
- Worker contract tests reject malformed checksums, byte-size mismatch,
  arbitrary R2 write keys, unverified blob references, and duplicate
  registrations with conflicting data.
- `swift test --package-path Packages/FramebaseKit`, the Worker test/typecheck
  commands, UI tests, and `git diff --check` pass.

## Later authorization gates

Passing this fixture gate does **not** start a real-library migration. A future
decision must explicitly approve the target library, manifest location,
bounded batch size, recovery window, live-device enrollment, Cloudflare dev or
production destination, and an observed copy-and-verify run. Local-original
retention remains a separate later decision after verified parity.
