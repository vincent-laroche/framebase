# Framebase

Framebase is a Mac-first, cloud-backed visual asset operating system. Its implemented first phase is a native local macOS asset manager that stores managed immutable originals in a user-owned library package while keeping logical folders, albums, metadata, and browsing state in a GRDB/SQLite catalog.

Overall product scope and delivery are governed by [`docs/MASTER_ROADMAP.md`](docs/MASTER_ROADMAP.md). The completed local-foundation implementation is documented in [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md).

## Requirements

- macOS 26+
- Apple Silicon
- Swift 6.3+
- Full Xcode 26 for application builds

## Development

Run package tests:

```sh
swift test --package-path Packages/FramebaseKit
```

Run the headless build gate through the project entrypoint:

```sh
./script/build_and_run.sh --verify
```

This command never kills or launches the GUI app. It runs `xcodebuild` for the
macOS target followed by the package tests, so it does not take focus from an
active desktop session. Native macOS UI tests are deliberately not part of the
local headless gate because XCTest drives the host desktop session; run them
only in an isolated CI/macOS test environment. The repository's macOS CI job
compiles and runs `FramebaseUITests` on its own runner, never on a developer's
active desktop.

The core local asset manager remains intentionally unsandboxed. Its development
cloud enrollment/catalog-sync path is separately double-gated in Settings and
is never enabled by default. There is no permanent asset deletion, and later
Finder, intelligence, workflow, and agent features remain governed by their
own roadmap phases.
