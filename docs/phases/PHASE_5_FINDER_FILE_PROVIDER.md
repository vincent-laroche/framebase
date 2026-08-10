# Phase 5 — Finder File Provider Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Make a cloud-backed Framebase library appear in Finder and standard macOS file pickers without creating a second catalog authority or risking original bytes.

**Architecture:** A pure Swift bridge maps Framebase identifiers and catalog snapshots to File Provider concepts. A signed NSFileProviderReplicatedExtension adapts that bridge only after the signing and App Group spike is valid. The extension uses FramebaseAPIClient and FramebaseSync for authenticated materialization; it never accesses R2, D1, or credentials directly.

**Tech Stack:** Swift 6.2, macOS 26, FileProvider, GRDB/SQLite, existing FramebaseDomain, FramebaseCatalog, FramebaseAPIClient, and FramebaseSync.

## Global Constraints

- Preserve AssetID, storageKey, original bytes, and logical folder semantics; Finder paths are projections only.
- Finder mutations use the same validation, audit, revision, conflict, outbox, and Trash rules as the macOS app.
- Synthetic libraries only until a distinct approval permits personal-library use.
- Current signing is ad hoc and this Mac has zero valid code-signing identities. Do not invent a team, provisioning profile, entitlement, App Group, or keychain group.
- Creating an extension target, App Group, entitlement, or File Provider domain requires Vincent to provide/select an Apple Developer Team and confirm that permission boundary.
- No Cloudflare resource, Worker deployment, secret, DNS, public URL, or production change is in scope.
- Fixed derivatives remain fail-closed unless the separately approved Cloudflare Images binding is completed.

## Entry Gate

The current Xcode project contains one ad-hoc signed app target and no File Provider extension. security find-identity -p codesigning -v reports 0 valid identities. Tasks 1–3 are safe pure-package work. Tasks 4–6 are blocked until the signing gate is passed. Before Task 5, the freshly paired synthetic Phase 3/4 lifecycle proof must include trash.write and library.preferences.write.

## File Map

| Path | Responsibility |
| --- | --- |
| Packages/FramebaseKit/Sources/FramebaseFileProviderCore/ProviderItemID.swift | Stable, filename-independent identifiers. |
| Packages/FramebaseKit/Sources/FramebaseFileProviderCore/FileProviderSnapshot.swift | Item snapshots, anchor, capability, and mutation proposal types. |
| Packages/FramebaseKit/Sources/FramebaseFileProviderCore/FileProviderMaterializer.swift | Bounded, checksum-verified materialization adapter. |
| Packages/FramebaseKit/Sources/FramebaseDomain/FileProviderProtocols.swift | Catalog bridge contract. |
| Packages/FramebaseKit/Sources/FramebaseCatalog/CatalogFileProviderRepository.swift | Catalog-derived snapshots, anchors, and receipts. |
| FileProviderExtension/ | Replicated extension and Finder error translation; created after signing gate. |
| App/AppContainer.swift and UI/Settings/FramebaseSettingsView.swift | Explicit domain registration, status, and removal controls. |

---

### Task 1: Add stable identifiers and pure snapshots

**Files:**
- Create: Packages/FramebaseKit/Sources/FramebaseFileProviderCore/ProviderItemID.swift
- Create: Packages/FramebaseKit/Sources/FramebaseFileProviderCore/FileProviderSnapshot.swift
- Create: Packages/FramebaseKit/Tests/FramebaseFileProviderCoreTests/ProviderItemIDTests.swift
- Modify: Packages/FramebaseKit/Package.swift

**Produces:** ProviderItemID, FileProviderItemSnapshot, FileProviderSyncAnchor, and FileProviderMutationProposal.

- [x] **Step 1: Write the failing tests**

~~~swift
func testAssetIdentifierRoundTripsWithoutFilename() throws {
    let item = ProviderItemID.asset(assetID)
    XCTAssertEqual(try ProviderItemID.parse(item.rawValue), item)
    XCTAssertFalse(item.rawValue.contains("summer-photo"))
}

func testMalformedProviderIdentifierFails() {
    XCTAssertThrowsError(try ProviderItemID.parse("fb://v1/asset/not-a-uuid"))
}
~~~

- [x] **Step 2: Confirm the tests fail**

Run: swift test --package-path Packages/FramebaseKit --filter ProviderItemIDTests

Expected: compile failure because the target does not exist.

- [x] **Step 3: Implement strict identity and snapshot types**

Use only fb://v1/root/<catalog UUID>, fb://v1/folder/<folder UUID>, fb://v1/asset/<asset UUID>, and fb://v1/trash/<catalog UUID>. Snapshots hold ID, parent ID, filename, content type, byte size, date, revision, and materialization state. They must not hold an original path, R2 key, token, or bytes.

- [x] **Step 4: Verify focused tests**

Run: swift test --package-path Packages/FramebaseKit --filter FramebaseFileProviderCoreTests

Expected: PASS for roots, folders, assets, trash, malformed values, and catalog isolation.

- [x] **Step 5: Commit**

~~~bash
git add Packages/FramebaseKit/Package.swift Packages/FramebaseKit/Sources/FramebaseFileProviderCore Packages/FramebaseKit/Tests/FramebaseFileProviderCoreTests
git commit -m "Add File Provider identity core"
~~~

### Task 2: Add catalog snapshots, anchors, and typed proposals

**Files:**
- Create: Packages/FramebaseKit/Sources/FramebaseDomain/FileProviderProtocols.swift
- Create: Packages/FramebaseKit/Sources/FramebaseCatalog/CatalogFileProviderRepository.swift
- Modify: Packages/FramebaseKit/Sources/FramebaseCatalog/FramebaseCatalog.swift
- Create: Packages/FramebaseKit/Tests/FramebaseCatalogTests/CatalogFileProviderRepositoryTests.swift

**Consumes:** Task 1 types plus existing asset, folder, Trash, revision, and sync-outbox repositories.

**Produces:** FileProviderRepository that emits snapshots and applies Finder proposals through canonical domain operations.

- [ ] **Step 1: Write the failing repository test**

~~~swift
func testRenameEmitsOneAnchoredChangeWithoutChangingStorageKey() async throws {
    let anchor = try await repository.currentAnchor()
    try await repository.apply(.renameAsset(assetID, displayName: "Finder Name.jpg"))
    let changes = try await repository.changes(since: anchor)
    XCTAssertEqual(changes.updated.map(\.itemID), [.asset(assetID)])
    XCTAssertEqual(try await assets.asset(id: assetID)?.storageKey, originalStorageKey)
}
~~~

- [ ] **Step 2: Confirm the test fails**

Run: swift test --package-path Packages/FramebaseKit --filter CatalogFileProviderRepositoryTests

Expected: compile failure because FileProviderRepository is missing.

- [ ] **Step 3: Add only additive catalog state**

Add a migration with file_provider_state and file_provider_operation_receipts. Store catalog ID, monotonic sequence, idempotency key, outcome, and remote revision only. Derive item metadata from canonical tables; do not duplicate image data, original paths, Finder paths, credentials, or storage keys.

- [ ] **Step 4: Implement proposal dispatch**

The repository must support item lookup, paged children, working-set changes, create folder, rename, move, and Trash proposals. It invokes the existing catalog repositories and durable cloud queue. Revision conflicts become typed retained conflicts; no local or remote winner is guessed.

- [ ] **Step 5: Verify migration and behavior**

Run: swift test --package-path Packages/FramebaseKit --filter CatalogFileProviderRepositoryTests

Expected: PASS from empty and upgraded catalogs, with anchor paging, repeat idempotency, conflict retention, and storage-key invariants.

- [ ] **Step 6: Commit**

~~~bash
git add Packages/FramebaseKit/Sources/FramebaseDomain Packages/FramebaseKit/Sources/FramebaseCatalog Packages/FramebaseKit/Tests/FramebaseCatalogTests
git commit -m "Add catalog File Provider bridge"
~~~

### Task 3: Add bounded materialization and offline error mapping

**Files:**
- Create: Packages/FramebaseKit/Sources/FramebaseFileProviderCore/FileProviderMaterializer.swift
- Create: Packages/FramebaseKit/Tests/FramebaseFileProviderCoreTests/FileProviderMaterializerTests.swift
- Modify: Packages/FramebaseKit/Sources/FramebaseSync/FramebaseSync.swift

**Produces:** FileProviderMaterializationService.

- [ ] **Step 1: Write failing materialization tests**

~~~swift
func testCloudOnlyAssetMaterializesAndVerifiesChecksum() async throws {
    let result = try await materializer.materialize(.asset(assetID))
    XCTAssertEqual(result.sha256, expectedSHA256)
    XCTAssertTrue(result.isVerified)
}

func testOfflineCloudOnlyAssetReturnsRecoverableError() async {
    await XCTAssertThrowsErrorAsync(try await materializer.materialize(.asset(assetID))) {
        XCTAssertEqual($0 as? FileProviderMaterializationError, .serverUnavailable)
    }
}
~~~

- [ ] **Step 2: Confirm the test fails**

Run: swift test --package-path Packages/FramebaseKit --filter FileProviderMaterializerTests

Expected: compile failure because the materializer is absent.

- [ ] **Step 3: Implement the minimum safe adapter**

Resolve an existing verified local original first. Only a remote-only asset may call FramebaseSync.materializeOriginal(for:). Recheck SHA-256 before returning the URL. Support cancellation and return only noSuchItem, notAuthenticated, serverUnavailable, or conflict. Eviction may remove derived/materialized copies only.

- [ ] **Step 4: Verify focused tests**

Run: swift test --package-path Packages/FramebaseKit --filter 'FileProviderMaterializerTests|FramebaseSyncTests'

Expected: PASS for local hit, on-demand retrieval, mismatch rejection, offline recovery, and cancellation.

- [ ] **Step 5: Commit**

~~~bash
git add Packages/FramebaseKit/Sources/FramebaseFileProviderCore Packages/FramebaseKit/Sources/FramebaseSync Packages/FramebaseKit/Tests/FramebaseFileProviderCoreTests
git commit -m "Add verified File Provider materialization"
~~~

### Task 4: Pass the signing and extension lifecycle spike

**Files:**
- Create: App/Framebase.entitlements
- Create: FileProviderExtension/FramebaseFileProvider.entitlements
- Create: FileProviderExtension/Info.plist
- Modify: Framebase.xcodeproj/project.pbxproj
- Create: docs/FILE_PROVIDER_SIGNING_SPIKE.md

**Blocked by:** valid Apple development identity, team identifier, and explicit App Group approval.

- [ ] **Step 1: Stop if the identity is still missing**

Run: security find-identity -p codesigning -v

Expected today: 0 valid identities found. Do not create entitlements or edit Xcode signing until Vincent selects an Apple Developer Team.

- [ ] **Step 2: Write the domain lifecycle smoke test**

~~~swift
func testSyntheticDomainCanBeAddedAndRemoved() async throws {
    let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier("com.vincentlaroche.framebase.fixture"),
        displayName: "Framebase Fixture"
    )
    try await manager.add(domain)
    defer { try? await manager.remove(domain) }
    XCTAssertTrue(try await manager.domains().contains(domain))
}
~~~

- [ ] **Step 3: Configure only approved capabilities**

Embed one File Provider extension, use the real selected team, and give the host and extension exactly one matching App Group. Add only the File Provider extension point and required Info.plist keys. Do not add broad keychain groups, network exceptions, or production signing settings.

- [ ] **Step 4: Inspect signed artifacts**

Run: ./script/build_and_run.sh --verify

Run: codesign -dvvv --entitlements :- DerivedData/Build/Products/Debug/Framebase.app

Run: codesign -dvvv --entitlements :- DerivedData/Build/Products/Debug/Framebase.app/Contents/PlugIns/FramebaseFileProvider.appex

Expected: approved development identity and matching App Group only; no cloud credentials.

- [ ] **Step 5: Verify synthetic lifecycle**

Run: xcodebuild -project Framebase.xcodeproj -scheme Framebase -destination 'platform=macOS' test -only-testing:FramebaseFileProviderTests/DomainLifecycleTests

Expected: synthetic domain add/remove passes and no personal library domain is registered.

- [ ] **Step 6: Commit**

~~~bash
git add App FileProviderExtension Framebase.xcodeproj docs/FILE_PROVIDER_SIGNING_SPIKE.md
git commit -m "Add signed File Provider extension spike"
~~~

### Task 5: Implement the replicated Finder adapter

**Files:**
- Create: FileProviderExtension/FramebaseFileProviderExtension.swift
- Create: FileProviderExtension/FramebaseFileProviderItem.swift
- Create: FileProviderExtension/FramebaseFileProviderEnumerator.swift
- Create: FileProviderExtension/FramebaseFileProviderError.swift
- Create: FileProviderExtensionTests/FramebaseFileProviderExtensionTests.swift

**Consumes:** Tasks 1–4.

- [ ] **Step 1: Write the failing adapter test**

~~~swift
func testFinderRenameUsesCanonicalOutbox() async throws {
    let item = try await extension.modify(item: finderItem(named: "New Name.jpg"), baseVersion: original.version)
    XCTAssertEqual(item.filename, "New Name.jpg")
    XCTAssertEqual(fakeSync.lastMutation, .rename(displayName: "New Name.jpg"))
}
~~~

- [ ] **Step 2: Confirm the test fails**

Run: xcodebuild -project Framebase.xcodeproj -scheme Framebase -destination 'platform=macOS' test -only-testing:FramebaseFileProviderTests

Expected: compile failure because the extension adapter is absent.

- [ ] **Step 3: Implement the bounded extension surface**

Implement item lookup, folder/working-set enumeration, fetch contents, create folder, rename, move, and delete. Map Finder deletion to Framebase Trash. Reject replacement-content uploads until an explicit replacement contract exists. Set measured low pipeline-depth values. Translate typed errors to File Provider errors without exposing internal metadata.

- [ ] **Step 4: Verify extension and app**

Run: xcodebuild -project Framebase.xcodeproj -scheme Framebase -destination 'platform=macOS' test -only-testing:FramebaseFileProviderTests

Run: ./script/build_and_run.sh --verify

Expected: PASS for enumeration, anchored changes, materialization, rename/move/create-folder/Trash, offline errors, and conflict propagation.

- [ ] **Step 5: Commit**

~~~bash
git add FileProviderExtension FileProviderExtensionTests Framebase.xcodeproj
git commit -m "Implement replicated Finder adapter"
~~~

### Task 6: Add host controls and run the synthetic acceptance proof

**Files:**
- Modify: App/AppContainer.swift
- Modify: UI/Settings/FramebaseSettingsView.swift
- Modify: FramebaseUITests/FramebaseUITests.swift
- Create: docs/FILE_PROVIDER_ACCEPTANCE.md
- Modify: PROJECT.md

- [ ] **Step 1: Write the failing host-control test**

~~~swift
func testFileProviderControlRequiresCloudParity() throws {
    launchFixture(cloudMode: .localOnly)
    XCTAssertFalse(app.buttons["settings.enableFileProvider"].isEnabled)
}
~~~

- [ ] **Step 2: Confirm it fails**

Run: xcodebuild -project Framebase.xcodeproj -scheme Framebase -destination 'platform=macOS' test -only-testing:FramebaseUITests/FileProviderControlsTests

Expected: control is absent.

- [ ] **Step 3: Add explicit opt-in and removal**

Permit registration only after pairing and parity checks. Show domain status, pending operations, materialized cache, and conflicts. Removing a domain must not delete the library, catalog, local originals, or remote originals.

- [ ] **Step 4: Run the fixture proof**

Run: ./script/build_and_run.sh --verify

Perform and record: add synthetic domain; restart host/extension; browse Finder and NSOpenPanel; open cloud-only fixture in a second app; verify checksum; rename/move; disconnect network; surface conflict; Trash; remove/re-add domain; verify unchanged storage keys.

- [ ] **Step 5: Commit and record exit evidence**

~~~bash
git add App UI FramebaseUITests docs/FILE_PROVIDER_ACCEPTANCE.md PROJECT.md
git commit -m "Add File Provider host controls and acceptance proof"
~~~

## Phase 5 Exit Checklist

- [ ] Finder and standard open panels show Framebase after restart.
- [ ] A cloud-only synthetic original opens through another app and passes checksum verification.
- [ ] Finder create-folder, rename, move, and Trash use Framebase validation, audit, outbox, and immutable keys.
- [ ] Offline and conflict behavior is recoverable and visible in the app.
- [ ] Repeated enumeration, eviction, materialization, and relaunch preserve state.
- [ ] The extension contains no Cloudflare/R2 credentials and no personal media or production resource was used.
