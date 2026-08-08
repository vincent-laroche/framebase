# Framebase Project Status

## Current status

Milestone 1 — domain, catalog, and managed library — is implemented and locally verified. Milestones 0 and 1 are complete; Milestone 2 is next.

The repository now contains:

- A first-launch flow to create `~/Pictures/Framebase Library.framebase` or open an existing library package, with successful-library persistence in app preferences.
- Safe package validation for the library root, managed directories, and SQLite catalog file, including symlink rejection.
- A GRDB catalog with WAL mode, foreign keys, persistent catalog identity, seeded Inbox, schema constraints, stable paging and sorting, observations, and concrete asset/folder/album repositories.
- Transactional folder operations, cycle protection, delete-to-Inbox receipts, exact restore, atomic asset batch insertion, and independent album membership.
- Actor-isolated managed-original storage with source-copy staging, immutable UUID/shard keys, strict resolution, collision protection, capability-scoped rollback, and staging recovery.
- App-container integration that opens/migrates the catalog, recovers staging, owns protocol-facing repositories/services, and keeps SQL/filesystem work outside SwiftUI views.
- A shared Xcode scheme whose UI Test action now runs the native foreground-window launch test.

## Verification

- Xcode 26.6 build 17F113 is installed and selected at `/Applications/Xcode.app/Contents/Developer`.
- `xcodebuild -license check` and `xcodebuild -checkFirstLaunchStatus` pass.
- `swift test --package-path Packages/FramebaseKit` passes 21 tests in 5 suites.
- `xcodebuild ... test -only-testing:FramebaseUITests` passes the foreground-window launch test.
- `./script/build_and_run.sh --verify` builds, launches, and confirms the app remains running.
- GitHub Actions run `31253440128` passes package tests, the app/UI-test-target build, and the app smoke launch for commit `e0f3e9a`.
- `git diff --check` passes.

## Active blocker

None for Milestone 2. Phase one remains intentionally local-only: no networking, authentication, Cloudflare, sync, AI, OCR, video, or permanent deletion has entered scope.

## Next

1. Begin Milestone 2 application-shell and native folder-management work using the ownership map in the implementation plan.
2. Build the native source-list sidebar and synchronize it through `LibraryWindowModel`.
3. Integrate keyboard-accessible, transactional, reversible folder create/rename/reparent/delete behavior.
4. Keep logical moves catalog-only and preserve all managed originals.

## Session log

- 2026-08-08 — Codex primary agent — Implemented the Milestone 0 repository, package, shared contracts, native app shell, Xcode project, UI-test scaffold, build/run entrypoint, Codex Run action, and CI workflow. Package build and direct application type-check pass. Full Xcode tests/build/launch remain gated by the local Xcode installation; remote CI is the next verification surface.
- 2026-08-08 — Codex primary agent — Full-Xcode CI passed on commit `a6a68db`: package tests, app/UI-test-target build, and application process smoke launch all succeeded. The foundation is pushed to `main`. Milestone 1 remains intentionally blocked until full Xcode 26 is installed and the project-local `--verify` launch succeeds on this Mac.
- 2026-08-08 — Codex primary agent with catalog and media sub-agents — Verified Xcode 26.6 license/first-launch state and closed the local Milestone 0 gate. Implemented Milestone 1 catalog persistence, managed-original storage, first-launch create/open orchestration, staged-file recovery, service integration, and the runnable UI-test scheme. Commit `e0f3e9a` is pushed to `main`; local verification passes 21 package tests, 1 native UI launch test, app build/launch verification, and whitespace checks, and GitHub Actions run `31253440128` is green. Next: begin Milestone 2.
