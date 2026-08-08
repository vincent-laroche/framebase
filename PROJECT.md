# Framebase Project Status

## Current status

Milestone 0 — repository and toolchain foundation — is implemented and verified in full-Xcode CI, but has not passed its final local toolchain gate.

The repository now contains:

- The native `Framebase.xcodeproj` application and UI-test targets.
- The local `Packages/FramebaseKit` package with `FramebaseDomain`, `FramebaseCatalog`, and `FramebaseMedia` products.
- Typed identifiers, models, queries, repository/service protocols, validation, and shared test fixtures.
- GRDB pinned exactly to 7.11.1 in `Package.resolved`.
- A SwiftUI `WindowGroup` shell, app container, window-scoped observable state, commands, toolbar, inspector, and settings scaffolds.
- The project-local `script/build_and_run.sh` entrypoint, Codex Run action, and macOS 26 GitHub Actions workflow.

## Active blocker

Full Xcode is not installed or selected. The active developer directory is `/Library/Developer/CommandLineTools`; `xcodebuild` cannot run. The Mac has approximately 27 GB free, so installing Xcode is not being attempted automatically. Swift 6.3.3 and the macOS 26.5 SDK are available for package-level compilation. The stripped Command Line Tools installation also lacks the Testing/XCTest runtime needed to link `swift test`.

Available verification passed:

- `swift build --package-path Packages/FramebaseKit`
- Direct Swift 6.3 type-check of all application sources against the built package modules
- Xcode project property-list validation
- Shared scheme/workspace XML validation
- Package manifest, CI YAML, run-script syntax, and whitespace checks
- Run-script prerequisite behavior (exits with the documented Xcode requirement)
- GitHub Actions run `31250963277` on the macOS 26 runner:
  - FramebaseKit tests passed under full Xcode.
  - The native application and UI-test target built successfully.
  - The generated `Framebase.app` launched and remained running for the process smoke check.

## Next

1. Free sufficient disk space, then install and select full Xcode 26.
2. Run `./script/build_and_run.sh --verify` and the UI smoke test locally.
3. Mark Milestone 0 complete only after that local gate passes.
4. Begin delegated Milestone 1 subsystem work using the ownership boundaries in the implementation plan.

## Session log

- 2026-08-08 — Codex primary agent — Implemented the Milestone 0 repository, package, shared contracts, native app shell, Xcode project, UI-test scaffold, build/run entrypoint, Codex Run action, and CI workflow. Package build and direct application type-check pass. Full Xcode tests/build/launch remain gated by the local Xcode installation; remote CI is the next verification surface.
- 2026-08-08 — Codex primary agent — Full-Xcode CI passed on commit `a6a68db`: package tests, app/UI-test-target build, and application process smoke launch all succeeded. The foundation is pushed to `main`. Milestone 1 remains intentionally blocked until full Xcode 26 is installed and the project-local `--verify` launch succeeds on this Mac.
