# Phase 4 Local Organization — Executable Plan

## Task 1: Tags and bulk membership foundation

1. Write catalog migration tests proving v1/v2 assets, folders, albums, catalog
   identity, original availability, and storage keys are unchanged after the
   additive tag migration.
2. Add `TagID`, `Tag`, validation, `TagRepository`, `CatalogTagRepository`,
   `tags` and `asset_tags` tables, indexes, and a named v3 GRDB migration.
3. Test/create/rename/list/delete tags; test atomic bulk add/remove membership,
   including rollback when any supplied asset or tag is invalid.
4. Expose `CatalogDatabase.tags`; keep UI unchanged for this task.
5. Verify focused catalog tests, then full package tests and diff hygiene.

## Task 2: Albums and tags in native UI

1. Add UI tests first for source-list albums/tags, create/rename/delete, and
   multi-selection membership editing.
2. Extend `LibraryWindowModel` through repositories only; retain AppKit/SwiftUI
   selection and observation boundaries.
3. Build minimal native sidebar and inspector controls with undo receipts.
4. Verify UI suite and a fixture-backed large-selection case.

## Task 3: Structured search and saved rules

1. Add query domain types and indexed catalog search for safe local fields.
2. Add SavedSearch/SmartCollection migrations and persistence tests.
3. Build search UI, stable paging/sorting, saved-search editing, and rule
   validation; do not add semantic/AI search.

## Task 4: Logical actions, local trash, and export

1. Add logical rename/move/reveal/export use cases with transaction/undo tests.
2. Add local trash receipts, restore, retention visibility, and no purge path.
3. Add duplicate candidates from verified checksums only; no auto-merge/delete.
4. Verify export checksum and a fixture restore drill.
