# Framebase macOS Implementation Plan

## Summary

Framebase will be a native, folder-first macOS asset manager built with Swift 6.3, SwiftUI, targeted AppKit bridges, GRDB/SQLite, Observation, and structured concurrency.

Repository inspection found:

- The local Framebase directory and GitHub repository were both empty at planning time.
- The machine runs macOS 26.6 with Swift 6.3.3 and macOS SDK 26.5.
- Full Xcode was not selected during planning; `xcodebuild` only saw Command Line Tools. Xcode 26 installation/selection is the first implementation prerequisite.

Locked decisions:

- macOS 26+, Apple Silicon first.
- Managed copies of imported originals.
- Still images only in phase one.
- 100,000-asset performance target.
- Initially unsandboxed.
- Deleting folders preserves originals by moving contained assets to Inbox.
- One local library package; multiple catalogs are deferred.
- No cloud, networking, authentication, AI, OCR, sync, workflows, or File Provider work.

## Architecture and Project Structure

Use a hybrid structure: an Xcode macOS app target for the application bundle, UI tests, resources, entitlements, and signing; local Swift packages for domain, persistence, and media services.

```text
Framebase/
├── Framebase.xcodeproj
├── App/
│   ├── FramebaseApp.swift
│   ├── AppContainer.swift
│   ├── FramebaseCommands.swift
│   └── LibraryWindowModel.swift
├── UI/
│   ├── AppShell/
│   ├── Sidebar/
│   ├── AssetBrowser/
│   ├── Inspector/
│   ├── Settings/
│   └── Shared/
├── Packages/FramebaseKit/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── FramebaseDomain/
│   │   ├── FramebaseCatalog/
│   │   └── FramebaseMedia/
│   └── Tests/
├── FramebaseUITests/
├── Resources/
├── docs/IMPLEMENTATION_PLAN.md
├── script/build_and_run.sh
├── .codex/environments/environment.toml
├── AGENTS.md
├── CLAUDE.md
└── PROJECT.md
```

### Layer boundaries

- `FramebaseDomain`: value models, typed identifiers, queries, repository protocols, commands, and validation. No SwiftUI, AppKit, GRDB, or persisted absolute paths.
- `FramebaseCatalog`: GRDB migrations, records, queries, observations, and repository implementations.
- `FramebaseMedia`: managed-original storage, import coordination, metadata extraction, previews, and thumbnail caching.
- App/UI target: scene composition, observable window state, SwiftUI views, AppKit representables, commands, and drag/drop presentation.
- UI invokes use cases and protocols only. It never performs SQL or mutates managed files directly.

Use GRDB 7.11.1, pinned exactly through Swift Package Manager and committed in `Package.resolved`: [GRDB v7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1).

### Local library layout

Create or open one managed package during first launch:

```text
~/Pictures/Framebase Library.framebase/
├── Catalog/
│   └── catalog.sqlite
├── Originals/
│   └── <two-character-shard>/<asset-uuid>.<extension>
└── Staging/
```

Derived thumbnails live outside the library package:

```text
~/Library/Caches/com.vincentlaroche.framebase/Thumbnails/
```

Logical folders never map to filesystem directories. Moving assets or folders changes catalog relationships only; original files remain at immutable UUID-based storage keys.

## Data Model and Public Interfaces

### Domain models

- `AssetID`, `FolderID`, and `AlbumID` are strongly typed UUID-backed identifiers.
- `Asset` contains:
  - `id`, `filename`, `displayName`, `parentFolderID`
  - `storageKey` and a transient resolved `localURL`
  - `mediaType`
  - optional `width` and `height`
  - `fileSize`
  - file `createdAt` and `modifiedAt`
  - `importedAt` and catalog `updatedAt`
  - `favorite`
  - `rating`, constrained to `0...5`
  - versioned `AssetMetadata`
- Absolute local URLs are not persisted as catalog truth. `AssetBlobStore` resolves `storageKey` to the current URL.
- `Folder` contains `id`, `name`, nullable `parentFolderID`, `createdAt`, `updatedAt`, `sortOrder`, and optional `systemKind`.
- A hidden system folder with `systemKind = inbox` is seeded during migration. Every asset has exactly one non-null folder ID.
- `Album` contains `id`, `name`, timestamps, and sort order.
- `AlbumAsset` provides the many-to-many relationship with `albumID`, `assetID`, `addedAt`, and sort order.
- Albums remain independent from folders. Album CRUD UI is deferred, but schema and protocols exist from the first migration.

### Metadata

`AssetMetadata` is versioned JSON containing typed sections for file, image, EXIF, TIFF, and other ImageIO properties. Frequently queried values remain normalized columns. Future OCR, embeddings, AI labels, and remote synchronization data must use separate tables rather than expanding this blob indefinitely.

### Repository interfaces

Expose asynchronous, `Sendable` protocols:

- `AssetRepository`: count/query pages, load details, observe query changes, update display name/rating/favorite, and move assets between folders.
- `FolderRepository`: load tree snapshots, create, rename, reparent, delete-preserving-assets, and observe tree changes.
- `AlbumRepository`: load albums and maintain membership, although UI mutation is deferred.
- `AssetBlobStore`: stage, commit, resolve, validate, and recover managed originals.
- `ThumbnailProvider`: request/cancel thumbnails and previews by asset fingerprint and target size.
- `MetadataExtractor`: validate ImageIO support and extract normalized metadata.
- `ImportCoordinator`: execute transactional batch imports and publish progress.

Use explicit `AssetQuery`, `AssetSort`, `AssetPage`, `FolderTreeSnapshot`, `CatalogChange`, and `ImportResult` types rather than passing view-specific flags into repositories.

### SQLite schema

The first GRDB migration creates:

- `folders`
- `assets`
- `albums`
- `album_assets`
- `catalog_settings`

Rules and indexes:

- UUIDs stored as lowercase text for future API portability.
- Dates stored as UTC integer milliseconds.
- Foreign keys enabled.
- `assets.parent_folder_id` and `folders.parent_folder_id` use `ON DELETE RESTRICT`.
- Album memberships cascade when an album or asset record is explicitly removed.
- Folder names are trimmed, non-empty, at most 255 characters, exclude `/` and NUL, and are case-insensitively unique among siblings.
- Folder moves validate against self-parenting and descendant cycles.
- Gap-based `Int64` sort ordering uses increments of 1024 and normalizes only when required.
- Index assets by folder plus each supported sort column, favorites, imported date, and modified date.
- Enable WAL mode and use `DatabasePool`.
- Persist no thumbnails or original image bytes in SQLite.

## UI and State Management

### Native window structure

Use:

- `WindowGroup("Framebase", id: "library")` for the primary restorable window.
- `Settings` for cache and library diagnostics.
- `NavigationSplitView` for sidebar and browser.
- SwiftUI `.inspector` for the right pane.
- Default window size around 1440×900 with an 1100×700 minimum.
- Native toolbar, source-list styling, adaptive colors, semantic materials, and standard macOS 26 Liquid Glass chrome.
- No custom opaque sidebar skin, oversized mobile controls, or decorative glass layers.

Toolbar actions:

- Import
- Sort menu
- Thumbnail-size slider
- Inspector toggle

Search and list mode remain deferred rather than appearing as non-functional controls.

### State ownership

- `AppContainer` owns shared repositories and services.
- Each window owns a `@MainActor @Observable LibraryWindowModel`.
- Feature-specific observable models cover sidebar, browser, inspector, and import progress.
- `@SceneStorage` persists per-window navigation, inspector visibility, and serialized folder-expansion state.
- `@AppStorage` persists thumbnail size, sort defaults, cache limit, and other user preferences.
- Repository observations use GRDB value observation bridged to async sequences.
- Navigation changes cancel the previous observation and thumbnail-prefetch tasks.

Core window state includes:

- `NavigationTarget`: All Assets, Inbox, Favorites, Folder, or Album.
- `AssetQuery` and `AssetSort`.
- Ordered visible asset IDs.
- Selected asset ID set.
- Selection anchor and keyboard-focused asset ID.
- Expanded folder ID set.
- Inspector visibility and import-operation state.

AppKit coordinators report events into this model. They must not become a second source of truth.

### SwiftUI versus AppKit

SwiftUI is sufficient for:

- App and settings scenes
- `NavigationSplitView` shell
- Toolbar and menus
- Inspector
- Preview and metadata sections
- Empty, loading, and error states
- Rating/favorite controls
- Import progress and confirmations

Use narrow AppKit bridges for:

1. `NSOutlineView` source-list sidebar

   Handles hierarchical disclosure, inline rename, keyboard focus, drop targeting, hover expansion, and folder reparenting. It also renders the Library, Folders, and Albums groups to avoid nested scrolling inside a SwiftUI sidebar.

2. `NSCollectionViewController` asset browser

   Handles reusable grid cells, native multi-selection, Command/Shift semantics, keyboard navigation, prefetching, drag sessions, drop validation, and visible-range updates.

3. `NSOpenPanel`

   Handles first-library selection and large multi-file imports.

SwiftUI `commands` and `FocusedValue` remain the primary command-routing system. AppKit responder-chain work is added only where selection or menu validation genuinely requires it.

## Core Workflows and Risk Controls

### Import

- Accept file selection and Finder-to-Framebase drops.
- Gate files through ImageIO-supported still-image types.
- Guarantee JPEG, PNG, HEIC/HEIF, TIFF, GIF first-frame, and system-supported WebP fixtures.
- Copy into `Staging`, validate decoding, extract metadata off the main actor, then atomically move to `Originals`.
- Insert catalog records in one database transaction after file commit.
- On database failure, remove only the newly managed copy.
- On cancellation or crash, recover abandoned staging files at next launch.
- Import into the selected folder; All Assets and Inbox import into the system Inbox.
- Allow duplicate imports in phase one. Content hashing and duplicate detection are deferred.

### Selection

- `NSCollectionView` supplies native click, Command-click, Shift-click, arrow, and Shift-arrow behavior.
- Selection is synchronized to stable Asset IDs, not index paths.
- The anchor follows the current sorted query.
- `Command-A` selects the current query’s ordered ID set.
- Changing sort preserves selected IDs and recalculates the range anchor.
- Inspector updates are coalesced so large selection changes do not trigger one query per asset.

### Drag and drop

Register private pasteboard types for asset and folder drag sessions.

- Internal asset drags carry a session token; an in-memory registry owns the selected ID snapshot. Large selections are not serialized into the pasteboard.
- Dropping assets on a folder updates only `parentFolderID` in one transaction.
- Folder drops reject Inbox, self, descendant, and no-op targets.
- Folder targets provide native hover highlighting and delayed expansion.
- Finder-to-Framebase file URLs trigger import.
- Dragging managed originals out to Finder is deferred.

### Folder deletion

Deleting a folder:

1. Presents a summary of descendant folders and assets.
2. Moves every contained asset to Inbox in one transaction.
3. Deletes the logical folder subtree.
4. Leaves all managed originals untouched.
5. Registers an in-session undo operation containing the prior folder hierarchy and asset assignments.

Asset deletion and permanent file deletion are not part of phase one.

### Large grid

- Load the sorted ordered ID list separately from lightweight grid records.
- Fetch grid records in pages of approximately 500 around visible indices.
- Use collection-view reuse and prefetch APIs.
- Never decode full-resolution images for grid cells.
- Cancel thumbnail work when cells leave the prefetch window.
- Use placeholders while metadata or thumbnails are pending.
- Apply database and thumbnail results on the main actor in bounded batches.

### Thumbnail and preview cache

- Downsample through ImageIO at the requested pixel size and display scale.
- Cache keys include asset ID, file-size/mtime fingerprint, target dimensions, and cache format version.
- Use an actor-isolated pipeline with bounded worker concurrency.
- Memory cache default: 256 MB, cost-accounted.
- Disk cache default: 5 GB with LRU eviction and atomic writes.
- Inspector previews use a separate larger-size cache and never load the original at unconstrained resolution.
- Corrupt cache files are discarded and regenerated.
- Thumbnail failures display a stable placeholder without invalidating the asset record.

### Folder expansion state

- Persist stable expanded Folder IDs per window and catalog.
- Prune IDs that no longer exist.
- Preserve expansion through rename and reparent because IDs do not change.
- Auto-expand a valid drop target after a short hover delay.
- Expansion is UI state, not synchronized domain data.

### Concurrency and consistency

- UI models and AppKit synchronization remain `@MainActor`.
- Import, file storage, metadata extraction, and thumbnail caching use actors or structured task groups.
- GRDB `DatabasePool` owns database concurrency.
- No unstructured background queues or synchronous disk work from view bodies.
- Folder and asset mutations commit before UI observation publishes their new state.
- Missing originals remain visible with a missing-file state; catalog records are never silently deleted.

## Multi-Agent Execution Strategy

Framebase should use bounded sub-agent workstreams after the project foundation and shared interfaces are stable. The purpose is to parallelize independent implementation work without fragmenting the architecture or allowing multiple agents to edit the same integration surfaces.

The maximum working configuration is one primary agent and three sub-agents. The primary agent remains accountable for the complete application, even when implementation work is delegated.

### Primary agent responsibilities

The primary agent is the architecture owner and integrator. It owns:

- Xcode project and scheme configuration
- Swift package manifests and dependency versions
- Shared domain identifiers, models, queries, and repository protocols
- `AppContainer`
- `LibraryWindowModel`
- Scene composition, commands, and top-level navigation
- Cross-feature data flow
- Integration of sidebar, grid, inspector, and repository observations
- Full builds, UI automation, performance verification, and finish-gate decisions
- Git staging, commits, and pushes
- `AGENTS.md`, `PROJECT.md`, and other handoff documentation

The primary agent must establish compiling domain interfaces before parallel implementation begins. Sub-agents must not independently redefine shared types to make their local work compile.

### Sub-agent workstreams

#### Catalog agent

Owns:

- `Packages/FramebaseKit/Sources/FramebaseCatalog/`
- Catalog-specific tests
- GRDB records and migrations
- `DatabasePool` configuration
- Asset queries, pagination, sorting, and observations
- Folder tree queries and transactional mutations
- Album and membership persistence
- Database constraints, indexes, and migration tests

The catalog agent implements the shared repository protocols defined by the primary agent. It must not modify those protocols, package manifests, application state, or UI code without approval from the primary agent.

#### Media agent

Owns:

- `Packages/FramebaseKit/Sources/FramebaseMedia/`
- Media-specific tests and fixtures
- Managed-original storage
- Import staging and crash recovery
- ImageIO validation and metadata extraction
- Thumbnail and preview generation
- Memory and disk caching
- Import cancellation, rollback, and failure reporting
- Missing or corrupt media detection

The media agent implements `AssetBlobStore`, `ThumbnailProvider`, `MetadataExtractor`, and import-service contracts defined by the primary agent. It must not introduce networking, cloud storage, AI processing, or unsupported media scope.

#### AppKit interaction agent

Owns:

- `UI/Sidebar/`
- `UI/AssetBrowser/`
- AppKit bridge tests and UI-hosted interaction tests
- `NSOutlineView` source-list implementation
- `NSCollectionView` grid implementation
- Native selection and keyboard behavior
- Reusable collection items and visible-range reporting
- Internal drag-session adapters
- Folder and asset drop validation at the presentation boundary
- Inline folder rename and disclosure behavior

The AppKit agent works against shared observable state and repository interfaces supplied by the primary agent. AppKit coordinators must remain narrow adapters and must not become an independent state-management layer.

### Shared-file ownership rules

Only the primary agent may modify:

- `Framebase.xcodeproj`
- Any `.xcworkspace` or scheme files
- `Package.swift`
- `Package.resolved`
- Shared domain models and repository protocols
- `AppContainer`
- `LibraryWindowModel`
- `FramebaseApp.swift`
- `FramebaseCommands.swift`
- `script/build_and_run.sh`
- `.codex/environments/environment.toml`
- `AGENTS.md`
- `CLAUDE.md`
- `PROJECT.md`

Sub-agents must not use broad formatting, code generation, `git add -A`, destructive Git operations, or cleanup commands that could alter another agent’s work.

All agents share the same working directory. Each agent must assume other edits may appear while it is working, preserve those edits, and adjust its implementation without reverting unrelated changes.

If a sub-agent discovers that its task requires a shared-interface or project-configuration change, it must report:

1. The exact missing or insufficient interface.
2. The proposed minimal change.
3. Which owned implementation is blocked.
4. The test or behavior the change enables.

The primary agent then decides and applies the shared change.

### Git and build coordination

The primary agent owns Git operations unless a sub-agent is explicitly assigned an isolated worktree.

In the shared working directory:

- Sub-agents edit only their assigned paths.
- Sub-agents do not create commits.
- The primary agent stages files explicitly by owned path.
- The primary agent creates atomic commits after integration and verification.
- No agent runs destructive Git recovery commands.

Sub-agents should run the narrowest relevant package or test target. The primary agent runs full Xcode builds and application launches serially to avoid DerivedData and process conflicts.

Agents must not run clean builds concurrently. Full build, launch, UI-test, and performance-test operations are integration activities owned by the primary agent.

### Execution gates

#### Gate 0 — Single-agent foundation

Milestone 0 is completed by the primary agent without parallel implementation.

Before sub-agents start, the following must exist and compile:

- Xcode project and application target
- Local Swift package structure
- Typed identifiers and domain models
- Repository and service protocols
- Initial application container
- Test fixture factories
- Project-local build/run script
- Codex Run action
- Basic unit-test and app-build commands

No production subsystem work is delegated before this gate passes.

#### Gate 1 — Parallel subsystem implementation

After Gate 0, the catalog, media, and AppKit agents may work concurrently inside their assigned paths.

Each sub-agent must return:

- Files changed
- Contracts implemented
- Tests added and run
- Known limitations
- Required integration work
- Any shared-interface concern that was not changed locally

A sub-agent must stop at its assigned boundary. It must not wire its subsystem directly into unrelated UI or persistence layers merely to demonstrate completion.

#### Gate 2 — Primary integration

The primary agent integrates the completed workstreams and owns all cross-boundary behavior, including:

- Repository observations into window state
- Thumbnail results into reusable grid cells
- Sidebar destination changes into asset queries
- Asset drag sessions into folder mutations
- Folder changes into sidebar snapshots
- Selection changes into inspector state
- Import progress into application presentation
- Error propagation and user-facing recovery states
- Undo registration across asynchronous mutations

No milestone is complete merely because its individual workstreams compile. The integrated application must satisfy that milestone’s exit criterion.

#### Gate 3 — Independent finish review

After Milestone 5 integration, assign a sub-agent as an independent reviewer.

The reviewer performs a read-only or test-only audit covering:

- Architecture boundary violations
- Main-actor blocking
- Unbounded tasks or cache growth
- AppKit and SwiftUI state duplication
- Multi-selection regressions
- Invalid drag/drop states
- Folder-cycle and deletion safety
- Original-file preservation
- SQLite migration and constraint coverage
- Missing accessibility or keyboard paths
- Deferred features accidentally entering scope
- Claims not supported by tests or runtime evidence

The reviewer reports findings by severity and does not perform broad rewrites. The primary agent assigns narrow fixes to the appropriate owner and reruns the full verification suite.

### Milestone ownership map

#### Milestone 0 — Repository and toolchain foundation

- Primary agent only.
- Exit gate: shared interfaces compile, the app launches, and the test scaffold runs.

#### Milestone 1 — Domain, catalog, and managed library

- Primary agent: domain contracts, catalog identity, library-opening orchestration, and integration.
- Catalog agent: migrations, repositories, observations, constraints, and tests.
- Media agent: local blob storage, staging, recovery, and tests.
- AppKit agent may prepare fixture-driven bridge scaffolds but must not depend on unfinished repositories.

#### Milestone 2 — Application shell and folder management

- Primary agent: window shell, observable state, commands, undo orchestration, and integration.
- AppKit agent: source-list sidebar, inline rename, expansion, keyboard behavior, and drop presentation.
- Catalog agent: folder mutations, cycle validation, delete-to-Inbox transaction, and tree observations.
- Media agent remains outside folder operations because logical moves do not move original files.

#### Milestone 3 — Import and media pipeline

- Media agent: import coordinator, metadata, thumbnails, previews, cache, cancellation, and recovery.
- AppKit agent: file-drop extraction and presentation callbacks only.
- Catalog agent: atomic catalog insertion and import-related observations.
- Primary agent: progress UI, destination selection, error handling, and end-to-end integration.

#### Milestone 4 — Professional asset browser

- AppKit agent: collection view, selection, keyboard navigation, reuse, prefetch callbacks, and internal drag sessions.
- Catalog agent: ordered ID queries, paged grid records, sorting, and query performance.
- Media agent: thumbnail delivery, cancellation, invalidation, and preview performance.
- Primary agent: shared selection state, drag-to-folder integration, inspector coordination, and full interaction verification.

#### Milestone 5 — Inspector, hardening, and finish gate

- Primary agent: inspector, settings, cross-feature polish, accessibility, full builds, UI tests, and performance acceptance.
- Sub-agents fix narrow issues within their owned subsystems.
- One sub-agent performs the independent finish-gate review after integration.

### Completion rule

A delegated task is complete only when:

- Its owned implementation is finished.
- Its tests pass.
- It conforms to the shared interfaces.
- It does not modify deferred scope.
- It reports remaining risks honestly.
- The primary agent has integrated and verified it in the running application.

Sub-agent completion is evidence for integration; it is not evidence that Framebase or a milestone is complete.

## Implementation Milestones

### Milestone 0 — Repository and toolchain foundation

- Install/select full Xcode 26 and verify `xcodebuild`.
- Initialize the local repository on `main` and connect it to `vincent-laroche/framebase`.
- Add `AGENTS.md`, `CLAUDE.md`, and `PROJECT.md` using the `01_projects` handoff convention.
- Create the Xcode app target, local `FramebaseKit` package, tests, and GRDB dependency.
- Set deployment target to macOS 26 and bundle ID to `com.vincentlaroche.framebase`.
- Keep App Sandbox disabled; keep the decision explicit in build settings.
- Add `script/build_and_run.sh` as the only build/run entrypoint with run, debug, logs, telemetry, and verify modes.
- Wire `.codex/environments/environment.toml` to that script.
- Add CI for package tests and the macOS app build.

Exit criterion: the empty native app builds, launches as a foreground `.app`, passes smoke tests, and can be run from the Codex Run action.

### Milestone 1 — Domain, catalog, and managed library

- Implement typed models, repository protocols, migrations, and local adapters.
- Implement first-launch create/open flow for the library package.
- Seed Inbox and catalog identity.
- Implement managed-original storage and staging recovery.
- Add repository, migration, constraint, and file-store integration tests.

Exit criterion: a library can be created, reopened, migrated, and queried without any UI depending directly on GRDB or filesystem paths.

### Milestone 2 — Application shell and folder management

- Build the three-pane window, toolbar, inspector visibility, and native source-list sidebar.
- Implement All Assets, Inbox, Favorites, and Albums placeholder destinations.
- Implement folder create, subfolder create, rename, reparent, delete-to-Inbox, expansion persistence, context menus, shortcuts, and undo.
- Add invalid-drop feedback and cycle protection.

Exit criterion: folder operations are keyboard-accessible, transactional, reversible, and preserve all original files.

### Milestone 3 — Import and media pipeline

- Implement file-panel and Finder-drop imports.
- Add ImageIO validation, metadata extraction, managed copies, progress, cancellation, and failure reporting.
- Implement thumbnail/preview generation and bounded memory/disk caching.
- Display deterministic placeholders and missing/corrupt states.

Exit criterion: supported still images import safely into Inbox or a chosen folder, survive relaunch, and render without full-resolution grid decoding.

### Milestone 4 — Professional asset browser

- Implement `NSCollectionView` grid, reusable cells, page loading, prefetching, sorting, and thumbnail sizing.
- Implement single, Command, Shift, keyboard, and select-all behavior.
- Implement multi-asset internal dragging and folder drop handling.
- Preserve selected IDs across observation updates and sorting.

Exit criterion: the grid behaves like a native Mac collection view and remains responsive with a 100,000-record synthetic catalog.

### Milestone 5 — Inspector, hardening, and finish gate

- Implement single-asset preview, filename, folder, dimensions, size, dates, favorite, rating, and metadata sections.
- Implement multi-selection count, total size, common/mixed folder, favorites count, rating summary, and date range.
- Add settings for cache limit, clear derived cache, reveal library, and diagnostics.
- Add unified logging and signposts around catalog queries, import, thumbnail generation, and grid stalls.
- Complete unit, integration, UI-hosted AppKit, UI automation, and performance tests.
- Perform Light/Dark mode, keyboard-only, drag/drop, window-restoration, and accessibility passes.
- Update `PROJECT.md` after every implementation session and milestone.

Exit criterion: all acceptance scenarios pass, no network calls exist, and the app is ready for regular local use without claiming sandboxing, signing, notarization, or distribution readiness.

## Test and Acceptance Plan

### Functional tests

- Create, rename, nest, move, and delete folders.
- Reject duplicate sibling names, invalid names, self-parenting, and descendant cycles.
- Confirm folder deletion moves all descendant assets to Inbox and undo restores the exact hierarchy.
- Import valid and invalid files, cancel batches, and recover interrupted staging.
- Verify folder and asset moves never alter original bytes or storage keys.
- Verify album membership does not change folder ownership.
- Verify favorite/rating changes persist and update Favorites immediately.

### Selection and interaction tests

- Plain click, Command-click, Shift-click, Shift-arrow, arrow navigation, and Command-A.
- Range selection after each supported sort.
- Drag one asset, multiple selected assets, and a large selected set.
- Reject invalid folder drops and preserve selection after successful moves.
- Keep keyboard focus visible while navigating beyond the viewport.
- Show correct inspector state for zero, one, and many selected assets.

### Persistence and recovery tests

- Fresh migration and migration replay.
- Foreign-key, uniqueness, and rating constraints.
- Library reopen after relaunch.
- Missing original, corrupt thumbnail, corrupt metadata, and failed import rollback.
- Expansion, thumbnail size, sort, inspector visibility, and window restoration.

### Performance acceptance

Using a release build and a 100,000-asset synthetic catalog on the current Apple Silicon Mac:

- First visible grid placeholders appear within two seconds after opening an existing catalog.
- Warm 500-item page queries complete in approximately 100 ms or less.
- Sorting rebuilds the ordered ID snapshot without blocking the main actor.
- Scrolling performs no synchronous image decode or database query on the main thread.
- Five minutes of aggressive scrolling remains under approximately 1 GB total app memory.
- Memory and disk cache limits remain enforced.
- Rapid scrolling cancels obsolete thumbnail work rather than allowing an unbounded queue.

Performance timings are recorded through XCTest metrics and signposts; CI treats functional correctness as mandatory and stores performance measurements without relying on unstable cross-machine absolute thresholds.

## Explicitly Deferred

- Cloudflare R2 and Cloudflare Images
- Remote API and networking
- Authentication and user accounts
- Local/cloud synchronization
- Finder File Provider
- OCR, embeddings, semantic search, classification, and facial recognition
- Workflows, MCP, and agent-facing APIs
- Video and guaranteed RAW support
- Album creation and editing
- List mode
- Filename or metadata search
- Duplicate detection
- Asset trash and permanent deletion
- Dragging managed originals out to Finder
- Image editing or transformations
- Multiple library catalogs
- App Sandbox migration
- Developer ID signing, notarization, App Store distribution, and auto-update

## Assumptions

- Phase one is a local personal application for the current Apple Silicon Mac.
- Unsandboxed status is temporary and must remain isolated behind `AssetBlobStore` so sandboxing can be introduced later.
- The library package is user-owned data; derived caches are disposable.
- Original bytes are immutable after import.
- Logical folders are catalog entities, not filesystem paths.
- GIF and other animated still-image containers use the first frame for thumbnails and preview.
- Future remote storage replaces or supplements repository and blob-store adapters without requiring the SwiftUI/AppKit feature layer to be rewritten.
