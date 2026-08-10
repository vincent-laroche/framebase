# Phase 9 — Personal and HSC Library Spaces

**Goal:** Let Framebase operate two deliberately separate libraries: Vincent's Personal Library and the Hair Solutions Co. Library, without allowing assets, cloud state, credentials, workflows, or review evidence to cross between them.

**Status:** Local library slice implemented and terminal-verified (2026-08-10). Separate production cloud onboarding remains planned and approval-gated.

## Product decision

Framebase is no longer constrained to one library package on a Mac. Each `.framebase` package remains an independent catalog and immutable-original store. The app may remember and switch among trusted local packages, but it never presents a merged cross-library grid, search result, workflow, or agent capability.

| Library | Local display name | Intended package | Current contents | Cloud target |
| --- | --- | --- | --- | --- |
| Personal | Personal Library | Existing `~/Pictures/Framebase Library.framebase` (retained until a separately reviewed rename) | 1,602 personal still-image originals | Dedicated private production target, not `framebase-blobs-dev` |
| Business | HSC Library | `~/Pictures/HSC Library.framebase` | Empty until Vincent selects an HSC image source | Dedicated private production target, distinct from Personal |

The existing package is registered as **Personal Library** by display name without moving its 1.2 GB originals. The HSC package starts empty; Framebase must not infer or copy business images from another project folder.

## Isolation invariants

1. **No shared catalog.** Each library has its own persistent catalog ID, SQLite files, managed-original tree, staging area, catalog revisions, outbox, review history, workflows, and agent audit history.
2. **No cross-library actions.** Search, selection, folder moves, tags, albums, workflows, CLI operations, agent credentials, approval tokens, and MCP requests resolve within one active catalog only.
3. **No cloud target reuse.** Personal and HSC need distinct private D1 databases, R2 buckets, Worker environment configurations, device identities, Keychain session accounts, Queue/Workflow resources, and future intelligence namespaces. The existing `framebase-*-dev` resources remain synthetic/development only.
4. **No automatic transfer.** Creating or registering a library never imports, relocates, renames, tags, uploads, or deletes any asset. HSC ingestion requires a separately selected source; personal-cloud migration requires a separately approved production target and verified canary.
5. **No deletion during migration.** A local original stays until its own library's remote object, catalog, and materialization read-back are verified, followed by a separate deletion/retention approval.

## Implementation slices

### 1. Local registry and safe switching

- [x] Add an app-owned `LibraryDescriptor` containing display name, category (`personal` / `hairSolutions`), validated root path, and observed catalog ID.
- [x] Migrate the existing last-opened preference into a Personal Library descriptor without moving the package.
- [x] Persist a bounded list of known local libraries in user preferences and re-open/revalidate the package/catalog before activation.
- [x] Add a toolbar/menu library switcher that shows the active library, opens a known library, and has explicit actions to create Personal or HSC library packages in Pictures.
- [x] Ensure switch resets transient selection, view, preview, and workflow state through the existing catalog-ID keyed lifecycle.

### 2. Create the empty HSC package

- [x] Create `~/Pictures/HSC Library.framebase` through the application package coordinator, seeded with its own Inbox and catalog ID.
- [x] Register it as HSC Library and verify it has zero assets and no file relation to Personal originals.
- [x] Keep the current Personal package at its existing path until a separate post-cloud rename review.

### 3. Separate production cloud onboarding

- [ ] Design two private production environments: Personal and HSC. Do not use the development bucket/database for either library's real media.
- [ ] For each library, require a separate, purpose-specific device enrollment and storage/control-plane namespace. Do not issue one credential that reaches both.
- [ ] Verify an authenticated canary upload, remote byte verification, catalog parity, and on-demand materialization within one library before any whole-library migration.
- [ ] Record real-media retention, budget, backup, and recovery terms before a deletion request is accepted.

## Verification

- [ ] Unit-test registry legacy migration, duplicate/root validation, unavailable-path handling, and catalog-ID mismatch rejection.
- [x] Terminal-build the macOS app and terminal-run focused creation/registration coverage for library creation and switching.
- [x] Verify Personal and HSC catalog IDs differ, both preserve an Inbox, HSC begins empty, and no original storage key appears in both packages.
- [x] Verify no production cloud resource or personal/HSC image transfer is created by this local-library slice.

## Explicit deferred decisions

- The existing package pathname is not renamed yet.
- No HSC source directory has been selected.
- No Personal or HSC production Cloudflare resource exists yet.
- No local originals are deleted, including after a successful cloud upload, without a separate retention/deletion approval.
