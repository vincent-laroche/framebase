# Framebase Agent Guide

Read `PROJECT.md` first, then this file, then `docs/IMPLEMENTATION_PLAN.md` before changing code.

## Authority

`docs/IMPLEMENTATION_PLAN.md` is the implementation source of truth. Follow its locked decisions, milestone gates, shared-file ownership rules, acceptance criteria, and deferred scope.

## Product boundary

Framebase is a local, folder-first macOS 26+ still-image asset manager for Apple Silicon. Phase one uses managed immutable originals, a GRDB/SQLite catalog, SwiftUI application composition, and narrow AppKit bridges. It has no networking, authentication, cloud, sync, AI, OCR, video, or permanent asset deletion.

## Working rules

- Preserve original file bytes and immutable storage keys.
- Logical folders are catalog relationships, never filesystem folders.
- UI code invokes domain protocols and never performs SQL or managed-file mutations directly.
- Keep app and AppKit state synchronized through `LibraryWindowModel`; bridge coordinators are adapters, not a second source of truth.
- Do not add deferred features to make a local implementation easier.
- Do not edit shared interfaces from a delegated subsystem without primary-agent approval.
- The primary agent owns project configuration, shared domain contracts, app composition, integration, Git operations, and this documentation.
- Run narrow tests during subsystem work. Full app builds, launches, UI tests, and performance checks are serialized integration work.
- Never use destructive Git recovery commands or overwrite another agent's edits.

## Build and verification

Use `./script/build_and_run.sh` as the only app build/run entrypoint once available. Package-level work may use `swift test --package-path Packages/FramebaseKit`.

The app target requires full Xcode 26. Do not claim the Xcode build or launch gate passed when only Command Line Tools are selected.

## Session handoff

Update `PROJECT.md` at the end of every implementation session with the current state, verification performed, blockers, next step, and agent name. Only change this file when a durable rule or path changes.
