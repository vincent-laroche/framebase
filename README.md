# Framebase

Framebase is a native, local-first macOS asset manager for large still-image libraries. It stores managed immutable originals in a user-owned library package while keeping logical folders, albums, metadata, and browsing state in a GRDB/SQLite catalog.

Implementation is governed by [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md).

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

The application remains intentionally unsandboxed during phase one. It contains no networking, authentication, cloud synchronization, AI, OCR, or permanent asset deletion.
