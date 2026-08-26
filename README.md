# Framebase

Framebase is a Mac-first, cloud-backed visual asset operating system for separately scoped private libraries. The native macOS app is the primary client: logical folders, albums, tags, metadata, search, workflows, and audit state live in a GRDB/SQLite catalog while managed originals remain immutable and UUID-keyed.

The repository has progressed beyond the original Phase 1 foundation. Local and development-only slices now include the cloud contract and Swift client/sync packages, organization and recovery primitives, File Provider core contracts, local Apple Vision analysis and review, durable local workflows with proposal/approval/undo, and a scoped local CLI/OpenAPI surface. The Cloudflare development Worker is deployed separately from the native app and remains fixture-oriented; it is not a production or personal-library migration.

The authoritative product and delivery status is [`docs/MASTER_ROADMAP.md`](docs/MASTER_ROADMAP.md). The completed Phase 1 implementation record remains [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md), while focused later-phase contracts live under [`docs/phases/`](docs/phases/).

## Current boundaries

The current build is not the complete Framebase product. The native File Provider extension and signing/App Group gate, migration of the personal library to cloud backing, cloud AI and semantic search, durable remote Queues/Workflows, remote MCP hosting, and production hardening remain unshipped or separately approval-gated. No production deployment, personal-media upload, or credential publication is implied by the repository plans.

## Requirements

- macOS 26+
- Apple Silicon
- Swift 6.3+
- Full Xcode 26 for application builds
- Node.js and npm for the Cloudflare Worker package

## Development

Run the native package tests:

```sh
swift test --package-path Packages/FramebaseKit
```

Build and verify-launch the native app through the repository entrypoint:

```sh
./script/build_and_run.sh --verify
```

Run the Cloudflare Worker tests and typecheck from its package directory:

```sh
cd Cloud/apps/api
npm test
npm run typecheck
npx wrangler deploy --dry-run --outdir /tmp/framebase-wrangler-dry-run
```

Native app builds require full Xcode 26. Cloudflare resource creation, deployment, DNS, credentials, and production changes remain approval-gated.
