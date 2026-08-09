# Fixture-Only Phase 3.1 Migration Implementation Plan

**Goal:** Build a restartable, copy-and-verify migration core for deterministic
fixture libraries only, proving Asset-ID preservation and remote byte/catalog
parity without touching a real Framebase library.

**Architecture:** Keep the current local Asset identity and storage key intact.
Add explicit local Blob/AssetBlob evidence, make the development Worker
canonical for remote folder/blob/asset rows, and drive migration through a
dedicated actor with an independent SQLite manifest. The actor only sees a
fixture-root capability and injected API; it has no `AppContainer` entrypoint.

**Tech stack:** Swift 6.3, Swift Testing, CryptoKit, GRDB 7, URLSession client
contracts, TypeScript, Hono, Vitest, in-memory fake D1/R2 test environment.

**Global constraints:**

- Fixture-only: never enumerate, hash, upload, or mutate a real user library.
- Preserve local original bytes, Asset IDs, and immutable storage keys.
- Never expose credentials or add network calls to committed Swift tests.
- No Cloudflare resource creation, deploy, secret mutation, or public delivery.
- Keep UI and AppContainer unchanged until this core passes its fixture gate.
- Do not commit or push unless Vincent explicitly asks.

## Task 1: Make the Worker’s existing canonical records and blob verification truthful

**Files:**

- Modify: `Cloud/apps/api/src/routes/blobs.ts`
- Modify: `Cloud/apps/api/src/routes/mutations.ts`
- Modify: `Cloud/apps/api/src/db/schema.sql`
- Modify: `Cloud/apps/api/test/blobs.test.ts`
- Modify: `Cloud/apps/api/test/mutations.test.ts`
- Modify: `Cloud/apps/api/test/changes.test.ts`
- Modify: `Cloud/apps/api/test/fakes/d1.ts` only if the new test SQL needs a
  supported fake-D1 capability

**Step 1: Write failing Worker tests.**

- Prove `upload-initiate` rejects non-64-character/non-hex lower-case hashes,
  negative or zero byte sizes, unsupported media types, and dangerous
  extensions.
- Prove the upload endpoint derives the R2 key from the pre-registered blob;
  an `assets.import` token cannot write an arbitrary key.
- Prove upload completion rejects a missing object, mismatched object size, and
  a byte digest that differs from the registered SHA-256; only a matching
  object transitions to `verified`.
- Prove duplicate upload initiation is idempotent only when immutable blob
  facts match, and conflicts when they do not.
- Prove each supported folder/metadata mutation updates its corresponding D1
  row as well as appending one change event. Verify idempotent replay does not
  add a second row or revision.

**Step 2: Implement the smallest secure Worker contract.**

- Introduce strict request parsers/validators local to the route or a small
  `src/validation.ts` helper; never trust a client-supplied R2 key.
- Change direct upload to address a registered blob ID (or a signed opaque
  upload capability) and resolve the key solely from `blobs.r2_key`.
- Calculate/compare the uploaded SHA-256 and byte size before marking the
  blob verified. Fixture uploads may buffer a single object; multipart remains
  explicitly deferred.
- Expand the D1 schema only with additive, replay-safe columns/indexes needed
  for checksum evidence or entity upserts. Preserve all existing IDs.
- Make `mutations.ts` write the actual folders/assets state from its already
  documented payload shapes before adding the change event/audit receipt. Keep
  response and idempotency shapes stable for `FramebaseCatalogSync`.

**Step 3: Verify the Worker.**

Run from `Cloud/apps/api`:

```sh
npx tsc --noEmit
npx vitest run
```

Expected: typecheck succeeds and the new negative, canonical-state, and
idempotency tests pass without a deploy.

## Task 2: Add an authenticated idempotent remote asset-registration contract

**Files:**

- Add: `Cloud/apps/api/src/routes/assets.ts`
- Modify: `Cloud/apps/api/src/index.ts`
- Modify: `Cloud/apps/api/src/types.ts`
- Modify: `Cloud/apps/api/src/db/schema.sql`
- Add: `Cloud/apps/api/test/assets.test.ts`
- Modify: `Packages/FramebaseKit/Sources/FramebaseAPIClient/APIModels.swift`
- Modify: `Packages/FramebaseKit/Sources/FramebaseAPIClient/APIClientProtocol.swift`
- Modify: `Packages/FramebaseKit/Sources/FramebaseAPIClient/FramebaseAPIClient.swift`
- Modify: `Packages/FramebaseKit/Tests/FramebaseAPIClientTests/FramebaseAPIClientTests.swift`

**Step 1: Write failing contract/client tests.**

- Define `POST /v1/assets/register` with a stable client mutation ID. Its body
  carries existing `assetId`, `blobId`/SHA-256, `folderId`, filename/display
  name, width/height, created/modified/imported timestamps, favorite, rating,
  and metadata JSON.
- Assert `assets.import` is required; the referenced blob must exist and be
  `verified`; the folder must exist; and foreign/malformed UUIDs fail.
- Assert the first registration creates exactly one canonical asset row and
  one change event, a same-facts retry returns the same result, and a
  conflicting retry fails without mutation.
- Stub the Swift client transport and assert exact method/path/header/body and
  typed API-error decoding.

**Step 2: Implement server and Swift contracts.**

- Add route registration in `src/index.ts`; use the same JWT scope middleware
  and idempotency receipt strategy as the mutations endpoint.
- Store every immutable/local-parity field needed to rebuild a fixture catalog.
  Additive remote columns are preferable to hidden JSON-only state where a
  value is required for comparison.
- Emit a typed `AssetRegistrationRequest`/`Response` in the Swift client. Do
  not overload metadata mutations with initial asset creation.
- Preserve endpoint version `/v1`; do not modify app UI or enroll devices.

**Step 3: Verify contracts.**

Run the Task 1 Worker commands and:

```sh
swift test --package-path Packages/FramebaseKit --filter FramebaseAPIClientTests
```

Expected: Worker asset-registration cases and URLProtocol client cases pass;
no live URL is contacted.

## Task 3: Add local Blob/AssetBlob persistence without changing Asset identity

**Files:**

- Modify: `Packages/FramebaseKit/Sources/FramebaseDomain/Models.swift`
- Add: `Packages/FramebaseKit/Sources/FramebaseDomain/MigrationModels.swift`
- Modify: `Packages/FramebaseKit/Sources/FramebaseCatalog/FramebaseCatalog.swift`
- Add: `Packages/FramebaseKit/Sources/FramebaseCatalog/CatalogBlobRepository.swift`
- Modify: `Packages/FramebaseKit/Sources/FramebaseCatalog/Records.swift`
- Modify: `Packages/FramebaseKit/Sources/FramebaseCatalog/CatalogAssetRepository.swift`
- Modify: `Packages/FramebaseKit/Sources/FramebaseDomain/RepositoryProtocols.swift`
- Modify: `Packages/FramebaseKit/Tests/FramebaseCatalogTests/CatalogDatabaseTests.swift`
- Add: `Packages/FramebaseKit/Tests/FramebaseCatalogTests/BlobMigrationTests.swift`

**Step 1: Write migration tests first.**

- Start from an existing Phase 1 fixture catalog, apply the additive migrator,
  then assert all Asset UUIDs, storage keys, folder assignments, original
  availability, and catalog identity are unchanged.
- Insert a Blob with SHA-256, byte size, content type, extension, R2 key,
  status, and checksum/etag evidence; associate it with an existing Asset.
- Assert a second association for the same current Asset is rejected unless a
  future explicit versioning API is added; assert duplicate checksum facts are
  idempotent and conflicting immutable facts fail.
- Verify query paths still return the original `Asset` surface unchanged.

**Step 2: Implement additive structures.**

- Add `Blob`, `AssetBlob`, `BlobUploadState`, and materialization/migration
  evidence structs as domain types. `Asset.storageKey` remains a local-file
  locator; it is not repurposed as a cloud key.
- Register a new named GRDB migration after the Phase 1 foundation. Create
  `blobs` and `asset_blobs` with foreign keys, immutable-fact constraints, and
  only the indexes the migration queries need.
- Expose a narrow `BlobRepository` from `CatalogDatabase`; do not make SwiftUI
  or `LibraryWindowModel` call it.

**Step 3: Verify catalog compatibility.**

```sh
swift test --package-path Packages/FramebaseKit --filter FramebaseCatalogTests
```

Expected: existing catalog tests remain green and the new migration proves
identity/storage-key preservation.

## Task 4: Build deterministic fixture-library and fake-remote test support

**Files:**

- Modify: `Packages/FramebaseKit/Sources/FramebaseTestSupport/FixtureFactory.swift`
- Add: `Packages/FramebaseKit/Sources/FramebaseTestSupport/FixtureLibraryFactory.swift`
- Add: `Packages/FramebaseKit/Sources/FramebaseTestSupport/InMemoryMigrationAPIClient.swift`
- Modify: `Packages/FramebaseKit/Package.swift`
- Add: `Packages/FramebaseKit/Tests/FramebaseMigrationTests/FixtureLibraryFactoryTests.swift`

**Step 1: Write failing fixture-safety tests.**

- Assert the factory only creates under an injected temporary directory whose
  final path component has the fixture sentinel; it rejects arbitrary URLs and
  every path outside that root.
- Build deterministic valid still-image fixtures with distinct, reproducible
  bytes and stable UUID/folder metadata. Do not read from Pictures, Photos,
  Cloudinary, or any user directory.
- Assert a 5,000-asset fixture build has predictable folder distribution and
  every byte file resolves from the managed fixture blob store.
- Add an in-memory API client that implements the real `APIClientProtocol`
  semantics for initiate/upload/complete/register/listing hooks and can inject
  failures/cancellation checkpoints without network access.

**Step 2: Implement test-support-only fixtures.**

- Keep image files tiny but valid and byte-distinct. Bound test data and
  concurrency so the acceptance suite is repeatable on a developer Mac and
  CI.
- Expose fixtures only to test targets and the planned development-only
  acceptance executable; do not add a user-facing import command.
- Update `Package.swift` with a dedicated `FramebaseMigration` target/test
  target only when its source exists. Depend on domain, catalog, media, API
  client, sync state, GRDB, and CryptoKit as needed; do not create an empty
  target.

**Step 3: Verify fixture isolation.**

```sh
swift test --package-path Packages/FramebaseKit --filter FixtureLibraryFactoryTests
```

Expected: factory tests prove all filesystem access is temporary and
fixture-scoped.

## Task 5: Implement the restartable fixture migration coordinator

**Files:**

- Add: `Packages/FramebaseKit/Sources/FramebaseMigration/FileDigestService.swift`
- Add: `Packages/FramebaseKit/Sources/FramebaseMigration/MigrationManifestStore.swift`
- Add: `Packages/FramebaseKit/Sources/FramebaseMigration/FixtureMigrationCoordinator.swift`
- Add: `Packages/FramebaseKit/Sources/FramebaseMigration/MigrationProgress.swift`
- Add: `Packages/FramebaseKit/Sources/FramebaseMigration/FixtureMigrationAuthorization.swift`
- Add: `Packages/FramebaseKit/Tests/FramebaseMigrationTests/FixtureMigrationCoordinatorTests.swift`
- Add: `Packages/FramebaseKit/Tests/FramebaseMigrationTests/MigrationManifestStoreTests.swift`

**Step 1: Write failing coordinator tests.**

- Create a small fixture catalog and assert the run transitions each asset
  through inventory, hashed, blob-registered, uploaded, verified, and
  asset-registered states. Assert the stored SHA-256 and byte size match the
  local file.
- Inject a failure after every state boundary. Reopen the manifest and prove a
  rerun skips verified work, retains the same Asset ID/idempotency key, and
  does not create duplicate remote blob or asset records.
- Cancel a run during hashing and upload; assert cancellation is explicit,
  local file bytes and keys are byte-for-byte unchanged, and no cleanup method
  for originals was invoked.
- Assert a non-fixture authorization/root is rejected before catalog inventory
  begins. Assert hashing runs off the main actor using an injectable digest
  implementation and a test probe.

**Step 2: Implement coordinator and durable manifest.**

- Use CryptoKit incremental SHA-256 over bounded `FileHandle` reads inside an
  actor/non-main-actor service. Do not call `Data(contentsOf:)` for a whole
  original.
- Put manifest state in the fixture library's `Sync/migration.sqlite`, with
  `asset_id`, immutable local facts, checksum, stable idempotency key, remote
  blob ID, remote asset ID, state, retry count, last error, and timestamps.
- Inventory local catalog records read-only. Resolve each local original
  through `AssetBlobStore`; then call client initiate/upload/complete/register
  operations under bounded concurrency. Use server idempotency for every
  mutating request.
- Persist after each durable state transition. Return structured progress and
  a report; never launch from `AppContainer` or write preferences.

**Step 3: Verify migration behavior.**

```sh
swift test --package-path Packages/FramebaseKit --filter FramebaseMigrationTests
```

Expected: completion, retry, resume, cancel, no-real-root, immutable-local,
and off-main-actor tests pass against the fake client.

## Task 6: Add remote parity rebuild and the 5,000-asset acceptance gate

**Files:**

- Add: `Packages/FramebaseKit/Sources/FramebaseMigration/FixtureParityVerifier.swift`
- Add: `Packages/FramebaseKit/Tests/FramebaseMigrationTests/FixtureMigrationAcceptanceTests.swift`
- Modify: `Packages/FramebaseKit/Tests/FramebaseMigrationTests/FixtureMigrationCoordinatorTests.swift`
- Modify: `PROJECT.md`

**Step 1: Write acceptance tests.**

- Migrate a deterministic 5,000-asset fixture library using the in-memory
  remote. Restart the coordinator at controlled intervals and assert all
  expected records complete exactly once.
- Rebuild a clean fixture catalog from canonical remote folders/assets/blobs
  (not a replay of the source catalog). Compare Asset IDs, folder parent IDs,
  display names, ratings, favorites, dimensions, metadata, checksum-to-asset
  associations, and original byte digests.
- Assert no migration operation changes local original file contents,
  modification keys, `storage_key`, or `original_available`.
- Bound the acceptance runtime and report duration/counters, but do not set an
  arbitrary performance claim until an observed baseline exists.

**Step 2: Implement parity verifier.**

- Define a typed remote catalog snapshot seam for the fake client; keep a
  future paginated Worker read endpoint out of this fixture-only slice unless
  the Worker contract tests demonstrate it is required.
- Produce a structured mismatch report containing only IDs, fields, and
  expected/actual checksums—not image bytes or user paths.

**Step 3: Run the complete local gate.**

```sh
swift test --package-path Packages/FramebaseKit
cd Cloud/apps/api && npx tsc --noEmit && npx vitest run
/usr/bin/xcodebuild -quiet -project Framebase.xcodeproj -scheme Framebase -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData test -only-testing:FramebaseUITests
git diff --check
```

Expected: all package, Worker, and UI tests pass; whitespace check is clean.
Then update `PROJECT.md` with exact counts, command results, the fact that no
live Cloudflare request/deploy occurred, and the next manual approval gate.

## Task 7: Optional manual development smoke test (separate approval only)

**Files:**

- Add if approved: `scripts/fixture_migration_smoke.swift` (uncommitted and
  deleted after the run) or an equivalent temporary local harness
- Modify after evidence: `PROJECT.md`

**Step 1: Stop unless Vincent explicitly approves this exact external write.**

The approval must authorize disposable development fixtures against
`framebase-api-dev`/its existing dev D1/R2 only. It must not imply approval to
deploy, change resources, enroll a persistent device, or point at a real
library.

**Step 2: If approved, run and clean up safely.**

- Enroll a disposable scoped device through the existing secret flow without
  printing secrets or tokens.
- Migrate a newly created temporary fixture library, download a bounded sample,
  compare digest/size, inspect exact D1/R2 counts, and revoke the device.
- Do not delete remote fixture records/objects unless the approval separately
  authorizes cleanup. Record their identifiers as dev fixtures if retained.

**Step 3: Record evidence.**

Update `PROJECT.md` with the non-sensitive result, exact command categories,
and cleanup/revocation status. A successful smoke test remains a fixture proof,
not real-library authorization.

## Implementation review checklist

- [ ] No source reads outside the deterministic fixture root.
- [ ] No `FileManager.removeItem` or original-availability mutation in the
      migration code path.
- [ ] All cloud write requests are idempotent and record stable IDs locally.
- [ ] Worker verified state requires actual digest and byte-size evidence.
- [ ] Local Asset IDs/storage keys survive database migration unchanged.
- [ ] Failure, cancellation, and restart paths have targeted tests.
- [ ] The 5,000-asset parity test is fake-only and reproducible.
- [ ] No deploy/resource/secret/live smoke action occurs without a new
      explicit approval.
