# Framebase Project Status

## Current status

Milestone 4 — professional asset browser — is implemented and locally verified. All planned Milestone 5 user-facing surfaces are now implemented; the final hardening/acceptance gate remains active.

The repository now contains:

- A first-launch flow to create `~/Pictures/Framebase Library.framebase` or open an existing library package, with successful-library persistence in app preferences.
- Safe package validation for the library root, managed directories, and SQLite catalog file, including symlink rejection.
- A GRDB catalog with WAL mode, foreign keys, persistent catalog identity, seeded Inbox, schema constraints, stable paging and sorting, observations, and concrete asset/folder/album repositories.
- Transactional folder operations, cycle protection, delete-to-Inbox receipts, exact restore, atomic asset batch insertion, and independent album membership.
- Actor-isolated managed-original storage with source-copy staging, immutable UUID/shard keys, strict resolution, collision protection, capability-scoped rollback, and staging recovery.
- App-container integration that opens/migrates the catalog, recovers staging, owns protocol-facing repositories/services, and keeps SQL/filesystem work outside SwiftUI views.
- A shared Xcode scheme whose UI Test action now runs the native foreground-window launch test.
- A native macOS source-list sidebar for Library, folders, and albums with persistent expansion, keyboard focus, inline rename, context menus, and validated folder drag/reparent behavior.
- Transactional folder create, rename, reparent, delete-to-Inbox, undo, and redo integration through `LibraryWindowModel`, including exact deletion receipt restoration.
- Still-image imports from the native file panel or Finder drop, routed to Inbox or the selected folder with progress, cancellation, per-file failures, batch catalog insertion, and managed-copy rollback.
- ImageIO pixel validation and normalized file/image/EXIF/TIFF metadata extraction for system-supported still images.
- ImageIO thumbnail/preview downsampling with cancellation, bounded memory caching, bounded LRU disk caching outside the library package, corrupt-cache regeneration, and stable missing/corrupt states.
- Catalog observations feed the visible browser immediately after import without decoding full-resolution originals in grid cells.
- A native `NSCollectionView` browser with reusable cells, stable ID selection, native Command/Shift/keyboard behavior, paging, thumbnail prefetch/cancellation, sorting refresh, select-all, and bounded large-selection inspector work.
- In-memory multi-asset drag sessions with validated drops onto regular folders or Inbox; catalog assignments update transactionally while original storage keys and bytes remain unchanged.
- A real single/multi-selection inspector with bounded previews, file and image metadata, folder/dimension/size/date details, aggregate summaries, and favorite/rating mutations.
- Working settings for thumbnail size, disk-cache limit, clearing derived thumbnails/previews, revealing the library, and local-only diagnostics.

## Verification

- Xcode 26.6 build 17F113 is installed and selected at `/Applications/Xcode.app/Contents/Developer`.
- `xcodebuild -license check` and `xcodebuild -checkFirstLaunchStatus` pass.
- `swift test --package-path Packages/FramebaseKit` passes 30 tests in 6 suites.
- `xcodebuild ... test -only-testing:FramebaseUITests` passes the full UI suite, including the create/rename/delete/undo/redo folder workflow.
- `./script/build_and_run.sh --verify` builds, launches, and confirms the app remains running.
- GitHub Actions run `31253440128` passes package tests, the app/UI-test-target build, and the app smoke launch for commit `e0f3e9a`.
- `git diff --check` passes.

## Active blocker

No implementation blocker. The remaining work is the Milestone 5 finish gate: large-catalog performance evidence, broader interaction/accessibility checks, diagnostics/logging review, and final acceptance documentation. Phase one remains intentionally local-only: no networking, authentication, Cloudflare, sync, AI, OCR, video, or permanent deletion has entered scope.

## Next

1. Run the Milestone 5 large synthetic-catalog and responsiveness acceptance checks.
2. Complete keyboard-only, Light/Dark, window restoration, drag/drop, and accessibility passes.
3. Review diagnostics/logging coverage and run a final source audit for deferred/network features.
4. Record the final acceptance result without claiming sandboxing, notarization, signing, or distribution readiness.

## Session log

- 2026-08-08 — Codex primary agent — Implemented the Milestone 0 repository, package, shared contracts, native app shell, Xcode project, UI-test scaffold, build/run entrypoint, Codex Run action, and CI workflow. Package build and direct application type-check pass. Full Xcode tests/build/launch remain gated by the local Xcode installation; remote CI is the next verification surface.
- 2026-08-08 — Codex primary agent — Full-Xcode CI passed on commit `a6a68db`: package tests, app/UI-test-target build, and application process smoke launch all succeeded. The foundation is pushed to `main`. Milestone 1 remains intentionally blocked until full Xcode 26 is installed and the project-local `--verify` launch succeeds on this Mac.
- 2026-08-08 — Codex primary agent with catalog and media sub-agents — Verified Xcode 26.6 license/first-launch state and closed the local Milestone 0 gate. Implemented Milestone 1 catalog persistence, managed-original storage, first-launch create/open orchestration, staged-file recovery, service integration, and the runnable UI-test scheme. Commit `e0f3e9a` is pushed to `main`; local verification passes 21 package tests, 1 native UI launch test, app build/launch verification, and whitespace checks, and GitHub Actions run `31253440128` is green. Next: begin Milestone 2.
- 2026-08-08 — Codex primary agent with catalog and AppKit sub-agents — Completed Milestone 2 with the native source-list sidebar, observed folder/album state, expansion persistence, keyboard and context-menu operations, validated drag/reparent behavior, delete-to-Inbox confirmation, and deterministic undo/redo. Local verification passes 24 package tests, the full native UI suite including create/rename/delete/undo/redo, app build/launch verification, and whitespace checks. Folder-edge polishing is intentionally deferred unless it blocks regular use; next is Milestone 3 import and media integration.
- 2026-08-08 — Codex primary agent — Completed Milestone 3 with native-panel and Finder-drop importing, ImageIO decode validation and metadata extraction, atomic catalog integration with cancellation/rollback/failure reporting, bounded thumbnail/preview caches, and visible missing/corrupt states. Local verification passes 30 package tests, the full native UI suite, the app build, and whitespace checks. Cloudflare remains unused because this phase is deliberately local-only. Next: native Milestone 4 asset-browser behavior.
- 2026-08-08 — Codex primary agent — Completed Milestone 4 and the functional Milestone 5 surfaces: native collection-view browsing, reusable thumbnail cells, stable multi-selection, keyboard/prefetch/paging behavior, catalog-only multi-asset folder drops, detailed single/multi inspector state, favorites/ratings, and working cache/library settings. Package tests, the full UI suite, app build/launch verification, and whitespace checks pass. Next: final large-catalog, accessibility, restoration, diagnostics, and scope acceptance evidence.
