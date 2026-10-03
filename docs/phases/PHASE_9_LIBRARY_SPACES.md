# Phase 9 — Personal, HSC, and Screenshots Library Spaces

**Goal:** Let Framebase operate three deliberately separate libraries: Vincent's Personal Library, the Hair Solutions Co. Library, and a Screenshots library for screenshots and other non-photo junk, without allowing assets, cloud state, credentials, workflows, or review evidence to cross between them.

**Status:** Local library slice implemented for all three spaces (2026-10-03). Separate production cloud onboarding remains planned and approval-gated.

## Product decision

Framebase is no longer constrained to one library package on a Mac. Each `.framebase` package remains an independent catalog and immutable-original store. The app may remember and switch among trusted local packages, but it never presents a merged cross-library grid, search result, workflow, or agent capability.

| Library | Local display name | Intended package | Current contents | Cloud target |
| --- | --- | --- | --- | --- |
| Personal | Personal Library | Existing `~/Pictures/Framebase Library.framebase` (retained until a separately reviewed rename) | 1,602 personal still-image originals | Dedicated private production target, not `framebase-blobs-dev` |
| Business | HSC Library | `~/Pictures/HSC Library.framebase` | Empty until Vincent selects an HSC image source | Dedicated private production target, distinct from Personal |
| Screenshots | Screenshots Library | `~/Pictures/Screenshots Library.framebase` | Empty until Vincent chooses a screenshots source | Dedicated private production target, distinct from Personal and HSC |

The existing package is registered as **Personal Library** by display name without moving its originals. The HSC and Screenshots packages start empty; Framebase must not infer or copy images from another project folder. Screenshots are not a tag or folder inside Personal. The Hair Solutions folder `09_reference/ops-screenshots` remains business reference material inside the HSC template.

## Isolation invariants

1. **No shared catalog.** Each library has its own persistent catalog ID, SQLite files, managed-original tree, staging area, catalog revisions, outbox, review history, workflows, and agent audit history.
2. **No cross-library actions.** Search, selection, folder moves, tags, albums, workflows, CLI operations, agent credentials, approval tokens, and MCP requests resolve within one active catalog only.
3. **No cloud target reuse.** Personal, HSC, and Screenshots need distinct private D1 databases, R2 buckets, Worker environment configurations, device identities, Keychain session accounts, Queue/Workflow resources, and future intelligence namespaces. The existing `framebase-*-dev` resources remain synthetic/development only.
4. **No automatic transfer.** Creating or registering a library never imports, relocates, renames, tags, uploads, or deletes any asset. HSC and Screenshots ingestion each require a separately selected source; personal-cloud migration requires a separately approved production target and verified canary.
5. **No deletion during migration.** A local original stays until its own library's remote object, catalog, and materialization read-back are verified, followed by a separate deletion/retention approval.

## Implementation slices

### 1. Local registry and safe switching

- [x] Add an app-owned library registration containing display name, category (`personal` / `hairSolutions` / `screenshots`), validated root path, and observed catalog ID.
- [x] Migrate the existing last-opened preference into a Personal Library descriptor without moving the package.
- [x] Persist a bounded list of known local libraries in user preferences and re-open/revalidate the package/catalog before activation.
- [x] Add a toolbar/menu library switcher that shows the active library, opens a known library, and has explicit actions to create Personal, HSC, or Screenshots library packages in Pictures.
- [x] Ensure switch resets transient selection, view, preview, and workflow state through the existing catalog-ID keyed lifecycle.

### 2. Create the empty HSC package

- [x] Create `~/Pictures/HSC Library.framebase` through the application package coordinator, seeded with its own Inbox and catalog ID.
- [x] Register it as HSC Library and verify it has zero assets and no file relation to Personal originals.
- [x] Keep the current Personal package at its existing path until a separate post-cloud rename review.

### 3. Screenshots library and per-space templates

- [x] Add `screenshots` as a third library space with its own package name, catalog stamp, and registry entry. Creating it does not import files.
- [x] Keep the Hair Solutions folder tree (`00_inbox` through `10_private`) as the HSC template only.
- [x] Add separate Personal and Screenshots starter templates. Personal uses people, places, events, projects, and `archive`. Screenshots uses screenshots, documents, captures, and `discard`. Neither copies the product taxonomy.
- [x] Apply a template only inside its own library space, through the existing review sheet. Tags stay `namespace:value` and do not replace folder membership.
- [x] Reject catalog-ID mismatches, unavailable package paths, and attempts to retarget a library from one space to another.

### 4. Separate production cloud onboarding

- [ ] Design three private production environments: Personal, HSC, and Screenshots. Do not use the development bucket/database for any library's real media.
- [ ] For each library, require a separate, purpose-specific device enrollment and storage/control-plane namespace. Do not issue one credential that reaches another library.
- [ ] Verify an authenticated canary upload, remote byte verification, catalog parity, and on-demand materialization within one library before any whole-library migration.
- [ ] Record real-media retention, budget, backup, and recovery terms before a deletion request is accepted.

## Verification

- [x] Unit-test registry legacy migration, duplicate/root validation, unavailable-path handling, and catalog-ID mismatch rejection.
- [x] Unit-test three-catalog isolation: nested folders, album membership, and tags that do not replace folders or cross spaces.
- [x] Terminal-build the macOS app and terminal-run focused creation/registration coverage for library creation and switching.
- [x] Verify Personal and HSC catalog IDs differ, both preserve an Inbox, HSC begins empty, and no original storage key appears in both packages. Screenshots uses the same isolation rule.
- [x] Verify no production cloud resource or personal/HSC image transfer is created by this local-library slice.

## Explicit deferred decisions

- The existing package pathname is not renamed yet.
- No HSC or Screenshots source directory has been selected.
- No Personal, HSC, or Screenshots production Cloudflare resource exists yet.
- No local originals are deleted, including after a successful cloud upload, without a separate retention/deletion approval.
