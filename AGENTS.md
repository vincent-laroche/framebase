# Framebase Agent Guide

Read `PROJECT.md` first, then this file, then `docs/MASTER_ROADMAP.md`, then the active phase plan before changing code. Use `docs/IMPLEMENTATION_PLAN.md` when work touches the completed Phase 1 foundation.

## Repository location

`/Users/vMac/01_projects/products/framebase` is the sole canonical local checkout. Do not create a persistent sibling clone or worktree without Vincent's current approval.

## Authority

`docs/MASTER_ROADMAP.md` is the overall product and delivery source of truth. Each active phase requires a focused plan under `docs/phases/`. `docs/IMPLEMENTATION_PLAN.md` remains the implementation record and authority for the completed Phase 1 local foundation.

## Product boundary
Framebase is a Mac-first, cloud-backed, folder-first visual asset operating system for separately scoped private libraries. Phase 1 is the native local foundation. Later local and development-only slices now exist for cloud contracts, Swift client/sync, organization and recovery, File Provider core contracts, local intelligence review, durable local workflows, and scoped CLI/agent contracts.

The native File Provider extension and signing/App Group gate, personal-library cloud migration, cloud AI and semantic search, durable remote Queues/Workflows, remote MCP hosting, and production hardening remain unshipped or separately approval-gated.

## Working rules

- Preserve original file bytes and immutable storage keys.
- Logical folders are catalog relationships, never filesystem folders.
- UI code invokes domain protocols and never performs SQL or managed-file mutations directly.
- Keep app and AppKit state synchronized through `LibraryWindowModel`; bridge coordinators are adapters, not a second source of truth.
- Do not add later-phase features before their focused phase plan and entry gate.
- Do not edit shared interfaces from a delegated subsystem without primary-agent approval.
- The primary agent owns project configuration, shared domain contracts, app composition, integration, Git operations, and this documentation.
- Run narrow tests during subsystem work. Full app builds, launches, UI tests, and performance checks are serialized integration work.
- Never use destructive Git recovery commands or overwrite another agent's edits.

## Build and verification

Use `./script/build_and_run.sh` as the only app build/run entrypoint once available. Package-level work may use `swift test --package-path Packages/FramebaseKit`.

The app target requires full Xcode 26. Do not claim the Xcode build or launch gate passed when only Command Line Tools are selected.

## Cloudflare
The repository contains a development-only Cloudflare Worker, D1 catalog, and private R2 bucket; these are not production or personal-library infrastructure. Before any Cloudflare inventory or implementation, read and follow `/Users/vMac/.codex/skills/hair-solutions-cloudflare-ops/SKILL.md`; keep resource creation, deployment, DNS, Access, credential, and production changes approval-gated. Never treat a roadmap or phase plan as deployment approval.

## Session handoff

Update `PROJECT.md` at the end of every implementation session with the current state, verification performed, blockers, next step, and agent name. Only change this file when a durable rule or path changes.
