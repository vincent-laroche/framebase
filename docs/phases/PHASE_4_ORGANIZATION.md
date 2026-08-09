# Phase 4 — Local Organization, Search, Trash, and Recovery

## Authority and entry conditions

This focused plan implements the next local/manual-management slice described
in `docs/MASTER_ROADMAP.md`. It follows the locally verified, fixture-only
Phase 3.1 gate; it does **not** authorize a real-library cloud migration,
cloud-backed mode, remote deletion, or any deployment.

## Goal

Make the existing native app a complete local manual asset manager: albums,
tags, indexed search, saved rules, local trash/restore, checksum-only duplicate
candidates, and verified exports—without changing immutable original keys or
introducing unreviewed destructive behavior.

## Scope and sequencing

1. Add additive catalog/domain models and migrations for `Tag`, `AssetTag`,
   `SavedSearch`, `SmartCollection`, `TrashReceipt`, and duplicate-candidate
   evidence. Preserve all existing Asset/Folder/Album IDs and storage keys.
2. Add protocol-facing repositories/use cases with transactional bulk edit,
   validation, undo receipts, observations, and query pagination. UI must not
   issue SQL or mutate managed originals directly.
3. Build albums and tags in the existing sidebar/browser/inspector, including
   create/rename/reorder/delete and multi-selection membership editing.
4. Build structured search over filename, folder path, normalized metadata,
   EXIF dates, rating/favorite, tag, and album. Add editable saved searches and
   rule-based smart collections only after the plain query surface is proven.
5. Add list mode and only the metadata columns that work with existing paging,
   selection, and drag behavior.
6. Add logical rename, Move To, Reveal, Copy/Export, and duplicate-candidate
   review. Export must verify output SHA-256; duplicates are suggestions only.
7. Add local trash/restore with a retention countdown. Purge remains a
   separately approved, explicit review operation and is not part of this
   phase's implementation.
8. Add sidecar/library-manifest export plus a documented fixture restore drill.

## Hard rules

- Local originals are never deleted, renamed, or moved by logical operations.
- Tags, search, trash, and duplicate candidates use local catalog state until a
  later cloud-sync phase has an approved conflict/tombstone design.
- No automatic merge, duplicate deletion, or purge.
- Every bulk operation has a bounded selection policy, an audit/undo receipt,
  and a test proving rollback on failure.
- No Phase 5 File Provider, intelligence, workflows, MCP/CLI expansion, or
  Cloudflare resource work is included.

## Completion evidence

Implementation status: the local catalog/UI requirements below are implemented.
The remaining native UI execution evidence is intentionally delegated to the
repository's isolated macOS CI runner; local development compiles that target
with `build-for-testing` but never drives an active desktop session.

- Package migrations preserve existing library identity, Asset IDs, folder
  relationships, original availability, and storage keys.
- UI tests cover albums/tags/search/trash/restore via the native app surface.
- Search returns stable paged results and saved rules survive reopen.
- Exported fixture originals match their stored checksums.
- A fixture restore drill rebuilds catalog relationships and reports any
  missing original explicitly.
- Full package tests, UI tests, build/launch verification, performance checks,
  and `git diff --check` pass.
