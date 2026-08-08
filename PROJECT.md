# Framebase Project Status

## Current status

Milestone 2 — application shell and folder management — is implemented and locally verified. Milestones 0 through 2 are complete; Milestone 3 import and media work is next.

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

## Verification

- Xcode 26.6 build 17F113 is installed and selected at `/Applications/Xcode.app/Contents/Developer`.
- `xcodebuild -license check` and `xcodebuild -checkFirstLaunchStatus` pass.
- `swift test --package-path Packages/FramebaseKit` passes 24 tests in 5 suites.
- `xcodebuild ... test -only-testing:FramebaseUITests` passes the full UI suite, including the create/rename/delete/undo/redo folder workflow.
- `./script/build_and_run.sh --verify` builds, launches, and confirms the app remains running.
- GitHub Actions run `31253440128` passes package tests, the app/UI-test-target build, and the app smoke launch for commit `e0f3e9a`.
- `git diff --check` passes.

## Active blocker

None for Milestone 3. Phase one remains intentionally local-only: no networking, authentication, Cloudflare, sync, AI, OCR, video, or permanent deletion has entered scope.

## Next

1. Implement Milestone 3 file-panel and Finder-drop imports into Inbox or the selected folder.
2. Add ImageIO validation, metadata extraction, managed copies, progress, cancellation, rollback, and failure reporting.
3. Add bounded thumbnail/preview caching and deterministic missing/corrupt placeholders.
4. Integrate the media pipeline without full-resolution grid decoding or any network dependency.

## Session log

- 2026-08-08 — Codex primary agent — Implemented the Milestone 0 repository, package, shared contracts, native app shell, Xcode project, UI-test scaffold, build/run entrypoint, Codex Run action, and CI workflow. Package build and direct application type-check pass. Full Xcode tests/build/launch remain gated by the local Xcode installation; remote CI is the next verification surface.
- 2026-08-08 — Codex primary agent — Full-Xcode CI passed on commit `a6a68db`: package tests, app/UI-test-target build, and application process smoke launch all succeeded. The foundation is pushed to `main`. Milestone 1 remains intentionally blocked until full Xcode 26 is installed and the project-local `--verify` launch succeeds on this Mac.
- 2026-08-08 — Codex primary agent with catalog and media sub-agents — Verified Xcode 26.6 license/first-launch state and closed the local Milestone 0 gate. Implemented Milestone 1 catalog persistence, managed-original storage, first-launch create/open orchestration, staged-file recovery, service integration, and the runnable UI-test scheme. Commit `e0f3e9a` is pushed to `main`; local verification passes 21 package tests, 1 native UI launch test, app build/launch verification, and whitespace checks, and GitHub Actions run `31253440128` is green. Next: begin Milestone 2.
- 2026-08-08 — Codex primary agent with catalog and AppKit sub-agents — Completed Milestone 2 with the native source-list sidebar, observed folder/album state, expansion persistence, keyboard and context-menu operations, validated drag/reparent behavior, delete-to-Inbox confirmation, and deterministic undo/redo. Local verification passes 24 package tests, the full native UI suite including create/rename/delete/undo/redo, app build/launch verification, and whitespace checks. Folder-edge polishing is intentionally deferred unless it blocks regular use; next is Milestone 3 import and media integration.
