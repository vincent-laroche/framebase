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

Build and launch the app through the project entrypoint:

```sh
./script/build_and_run.sh
```

The current Phase 1 application remains intentionally unsandboxed. It contains no networking, authentication, cloud synchronization, AI, OCR, or permanent asset deletion. Those capabilities are planned in later roadmap phases and must not be described as already built.
