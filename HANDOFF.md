# Handoff — Framebase browser hardening (2026-08-08)

## Where the work is

Worktree: `/Users/vMac/01_projects/private_apps_and_products/framebase/.claude/worktrees/framebase-photo-import-a78197`
Branch: `claude/framebase-photo-import-a78197` — **2 commits ahead of `origin/main`, unpushed.**

There is a second, near-identical worktree (`...-handoff-73b703`) that is a clean checkout of the
base commit `14072aa`. **Ignore it.** All work is in `a78197`.

Two files to know about before you start:

- `docs/MASTER_ROADMAP.md` exists **only in the canonical checkout**
  (`/Users/vMac/01_projects/private_apps_and_products/framebase/docs/`) and is untracked there.
  It is **not** in this worktree. Read it from the canonical path.
- The canonical checkout has unrelated uncommitted work (`AGENTS.md`, `PROJECT.md`, `README.md`,
  `docs/`, `.claude/`, `GEMINI.md`, `.codex/`). **Do not touch it.**

## Read order

`PROJECT.md` → `AGENTS.md` → `docs/IMPLEMENTATION_PLAN.md` (the implementation authority) →
`docs/MASTER_ROADMAP.md` (canonical checkout only).

## What just happened

Phase one was reported "complete and locally verified," but the browser had never been run with
real content. Loading ~1,600 real photographs exposed five defects. All are fixed, across two
commits.

**`0a64949` — import validation, cell registration, render loop**

- Import validation decoded a thumbnail at `kCGImageSourceThumbnailMaxPixelSize: 1`. ImageIO
  returns nil at that size for some valid iPhone JPEGs (captures carrying both a JFIF APP0 segment
  and EXIF), so 20 real photographs were rejected as unreadable. Measured across 1,602 files:
  size 1 → 20 rejected, size 2 → 19, size 4 and above → 0. Constant is now
  `FramebaseMediaFoundation.importValidationMaxPixelSize = 32`.
- `NSCollectionView` item-class registration ran before the layout was assigned. Assigning a layout
  discards registrations, so the first dequeued cell searched for a nib named
  `FramebaseAssetCollectionItem`, which does not exist, and AppKit raised. Registration moved into
  `loadView()` after the layout.
- **The browser never finished a single thumbnail.** `apply` reloaded visible items on every
  observed change, which re-fired `didEndDisplaying`/`willDisplay`; the cancel path cleared the
  in-flight `.loading` state, so every arriving state change cancelled and restarted every visible
  request. Measured: 100% CPU, ~108,000 `willDisplay` calls in 20 seconds, 8,972 `apply` calls,
  **zero** thumbnails written to disk. Visible cells are now reconfigured in place, layout is
  invalidated only when item size changes, and `requestThumbnail` publishes its observed state off
  the layout pass.

**`52603f5` — captions, folder titles, select-all**

- Cell image views sized themselves from the image they held, which outranked the cell constraints.
  Thumbnails spilled past the cell background and pushed the filename caption out of view; only
  cells whose image happened to be smaller than the cell were captioned.
- `NavigationTarget` is an identifier and cannot name a folder, so selecting one titled the window
  and the empty state with the literal word "Folder". The resolved title now comes from the observed
  folder and album snapshots.
- `NSCollectionView` answers `selectAll:` from the responder chain and selects only realized cells,
  so `⌘A` and `Assets ▸ Select All` disagreed on a paged folder. Both now run one code path.

## The library and the import CLI

`~/Pictures/Framebase Library.framebase` — 1,602 assets, 1.2 GB, 174 logical folders + Inbox.
Top-level: `01_library`, `02_shopify`, `03_blog`, `06_private`. Source files in `~/Downloads` are
untouched. The 3 files that did not import are `.mp4` — correctly rejected, video is deferred scope.

`framebase-import` is a **development-only** CLI that mirrors a source tree as logical catalog
folders, running one normal import batch per directory through the same `ManagedImportCoordinator`,
`ManagedAssetBlobStore`, `ImageIOMetadataExtractor`, and repositories the app uses. No direct SQL, no
filesystem writes outside the library package. Idempotent: skips filenames already present in the
destination folder.

```bash
swift build --package-path Packages/FramebaseKit --product framebase-import
```

```bash
./Packages/FramebaseKit/.build/debug/framebase-import --library "$HOME/Pictures/Framebase Library.framebase" --dry-run "$HOME/Downloads/01_library_2026-08-06_04_46=01_library"
```

App preference `framebase.libraryRootPath` is set, so the app opens straight into the library
instead of the first-run setup screen.

## Verified state

A hands-on pass over the real library confirmed working: thumbnail grid, sidebar folder hierarchy,
single and multi selection, aggregate inspector, full EXIF detail including camera and lens,
favourites and the Favorites smart view, star ratings, all six sort keys with direction, catalog-only
drag between folders, the thumbnail-size slider, and both Settings tabs — which report
Network: Disabled and Original storage: Managed locally.

The process settles at 0% CPU, the thumbnail cache fills, and no crash reports are produced.

Gate at handoff: 32 package tests, 4 UI tests, `./script/build_and_run.sh --verify`,
`git diff --check`.

## Open work, in priority order

1. **Two unconfirmed selection defects.** Against the 261-asset `01_library/product-reference/
   hair-systems` folder: `⌘A` did nothing at all (while `Assets ▸ Select All` correctly selected
   261), and clicking one cell would not collapse a 261-item selection back to one. Both were
   observed through synthetic clicks. The second may be an artifact — AppKit defers deselection to
   mouse-up so a multi-selection can be dragged. **Confirm by hand or with a scaled fixture before
   fixing. Do not fix on speculation.**

2. **Build the scaled-fixture and screenshot test harness.** Highest-leverage item. The current UI
   tests cannot catch the class of bug that actually shipped. Two additions fix that:
   - Seed a large fixture library (300+ varied, realistically-sized images) in test setup via the
     `framebase-import` CLI and point the UI test at it. Scale is where these bugs live.
   - Capture `XCUIScreen.main.screenshot()` as an attachment and extract the PNG from the
     `.xcresult` to inspect. The caption-overflow bug was invisible to both existence and
     frame-geometry assertions but obvious in a screenshot.
   With those in place, item 1 likely becomes reproducible.

3. **Decide with Vincent: does recursive folder-tree import become a real feature?** He is replacing
   Cloudinary, so bulk folder ingest is a genuine gap. Today it exists only as the dev CLI; in-app
   import is flat (one batch → one destination). Scope beyond phase one — needs his call.

4. Continue the roadmap per `docs/MASTER_ROADMAP.md`.

## Gotchas that cost real time

- **A green UI suite proves very little here.** Three of the four assertions added this session
  passed with their fix reverted. Fixture images decode faster than a render loop can starve them
  and stay smaller than a cell, so they reproduce neither the loop nor the overflow. **Always verify
  a new assertion fails without its fix.** Only the folder-title assertion was confirmed to
  discriminate (`Window titles: ["Folder"]`).
- **A wedged app makes XCUITest lie.** While the render loop pegged the main thread, XCUITest
  reported "no window found" for every test, including `testMainWindowLaunches`. That is not a
  window bug — the app cannot answer accessibility queries. Check CPU before believing it.
- **Signposts are not log messages.** `log stream --predicate 'subsystem == "com.vincentlaroche.framebase"'`
  returns nothing, because the thumbnail path only emits `OSSignposter` intervals. Zero lines is not
  evidence of zero activity.
- **Never mutate `@Observable` state from `willDisplay` or `prefetchItemsAt`.** AppKit calls those
  inside `NSHostingView.layout()`; publishing an observed change there makes AppKit raise from
  `_postWindowNeedsUpdateConstraints`. Register de-duplication in the non-observed `thumbnailTasks`
  and let the visible state land on a later turn.
- **Never `reloadItems` to push state into cells.** It re-fires `didEndDisplaying`/`willDisplay`, and
  the cancel path clears in-flight `.loading` state. Reconfigure visible cells in place.
- **Assigning `collectionViewLayout` discards item-class registrations.** Register after.
- **`screencapture` needs Screen Recording permission** for the process running it, and the window
  may sit on a secondary display — check `CGWindowListCopyWindowInfo` before concluding the app has
  no window.

## Rules

- Preserve original file bytes and immutable storage keys. Logical folders are catalog
  relationships, never filesystem folders.
- UI code invokes domain protocols; never SQL or managed-file mutations directly.
- Phase one is local-only: no networking, authentication, cloud, sync, AI, OCR, video, or permanent
  deletion.
- Run narrow tests during subsystem work; full builds, launches, and UI runs are serialized
  integration work.
- Prefer XCUITest over driving the user's screen. Use passive `screencapture` when you need pixels
  from the real library, and ask before using Computer Use.
- **Vincent's real photo library is live data.** If you exercise mutating operations (moves,
  ratings, favourites), make them reversible and restore state afterward. `06_private/sensitive`
  contains identity documents (national ID, registration certificates) — local only, no networking,
  but handle accordingly.
- Update `PROJECT.md` at the end of every implementation session per `AGENTS.md`.

## Verification gate

```bash
swift test --package-path Packages/FramebaseKit
```

```bash
xcodebuild -project Framebase.xcodeproj -scheme Framebase -configuration Debug -destination "platform=macOS" -derivedDataPath DerivedData test -only-testing:FramebaseUITests
```

```bash
./script/build_and_run.sh --verify
```

```bash
git diff --check
```

Use `-only-testing:FramebaseUITests/FramebaseUITests/<testName>` while iterating — the full target
re-runs a ~20 second folder/undo/redo test on every invocation.
