import Foundation
import FramebaseAPIClient
import FramebaseMigration
import Testing

final class InMemoryMigrationAPIClient: APIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var uploaded: [String: Data] = [:]
    private var registered: Set<String> = []
    private var initiateCalls = 0
    private var uploadCalls = 0
    private var completeCalls = 0
    private var registerCalls = 0
    private var remainingUploadFailures: Int
    private let uploadDelayNanoseconds: UInt64
    private var uploadStarted = false
    private var registrationRequests: [String: AssetRegistrationRequest] = [:]

    init(failUploadCount: Int = 0, uploadDelayNanoseconds: UInt64 = 0) {
        self.remainingUploadFailures = failUploadCount
        self.uploadDelayNanoseconds = uploadDelayNanoseconds
    }

    var registeredAssetIDs: Set<String> { lock.withLock { registered } }
    var initiateCallCount: Int { lock.withLock { initiateCalls } }
    var uploadCallCount: Int { lock.withLock { uploadCalls } }
    var completeCallCount: Int { lock.withLock { completeCalls } }
    var registerCallCount: Int { lock.withLock { registerCalls } }
    var uploadHasStarted: Bool { lock.withLock { uploadStarted } }
    var registrations: [String: AssetRegistrationRequest] { lock.withLock { registrationRequests } }
    func uploadedData(blobID: String) -> Data? { lock.withLock { uploaded[blobID] } }

    func health() async throws -> HealthResponse { fatalError("not used") }
    func enroll(enrollmentSecret: String, request: EnrollRequest) async throws -> EnrollResponse { fatalError("not used") }
    func fetchChanges(after: Int, limit: Int) async throws -> ChangesResponse { fatalError("not used") }
    func initiateBlobUpload(_ request: BlobUploadInitiateRequest) async throws -> BlobUploadInitiateResponse {
        lock.withLock { initiateCalls += 1 }
        return BlobUploadInitiateResponse(blobId: request.sha256, r2Key: "blobs/\(request.sha256).\(request.originalExtension)", uploadUrl: "fixture://\(request.sha256)", expiresAt: "never")
    }
    func uploadBlobBytes(_ data: Data, contentType: String, toRelativePath relativePath: String) async throws -> BlobUploadDirectResponse {
        let shouldFail = lock.withLock {
            uploadCalls += 1
            uploadStarted = true
            guard remainingUploadFailures > 0 else { return false }
            remainingUploadFailures -= 1
            return true
        }
        if shouldFail { throw APIClientError.transport(message: "injected fixture upload failure") }
        if uploadDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: uploadDelayNanoseconds) }
        let key = String(relativePath.dropFirst("fixture://".count))
        lock.withLock { uploaded[key] = data }
        return BlobUploadDirectResponse(status: "uploaded", key: key, size: data.count)
    }
    func uploadBlobFile(at fileURL: URL, contentType: String, toRelativePath relativePath: String) async throws -> BlobUploadDirectResponse {
        try await uploadBlobBytes(Data(contentsOf: fileURL), contentType: contentType, toRelativePath: relativePath)
    }
    func completeBlobUpload(_ request: BlobUploadCompleteRequest) async throws -> BlobUploadCompleteResponse {
        lock.withLock { completeCalls += 1 }
        return BlobUploadCompleteResponse(status: "verified", blobId: request.sha256, size: request.byteSize)
    }
    func downloadBlob(id: String) async throws -> BlobDownload { fatalError("not used") }
    func registerAsset(_ request: AssetRegistrationRequest, idempotencyKey: String) async throws -> AssetRegistrationResponse {
        lock.withLock {
            _ = registered.insert(request.assetId)
            registrationRequests[request.assetId] = request
            registerCalls += 1
        }
        return AssetRegistrationResponse(status: "registered", assetId: request.assetId, blobId: request.blobId, revision: registeredAssetIDs.count)
    }
    func submitMutations(_ request: MutationsRequest, idempotencyKey: String) async throws -> MutationsResponse { fatalError("not used") }
}

private final class MigrationProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MigrationProgress] = []

    func record(_ progress: MigrationProgress) { lock.withLock { values.append(progress) } }
    var states: [MigrationManifestState] { lock.withLock { values.map(\.state) } }
}

@Suite("Fixture migration coordinator", .serialized)
struct FixtureMigrationCoordinatorTests {
    @Test("A fixture run hashes, uploads, verifies, and registers every asset without changing local originals")
    func migratesFixtureAssets() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let authorization = try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL)
        let manifest = try MigrationManifestStore(databaseURL: fixture.rootURL.appending(path: "Sync/migration.sqlite", directoryHint: .notDirectory))
        let api = InMemoryMigrationAPIClient()
        let before = try fixture.assets.map { asset in
            try Data(contentsOf: fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory))
        }

        let coordinator = FixtureMigrationCoordinator(authorization: authorization, catalog: fixture.catalog, originalsURL: fixture.originalsURL, manifest: manifest, apiClient: api)
        let report = try await coordinator.run()

        #expect(report.registeredAssetIDs == Set(fixture.assets.map { $0.id }))
        #expect(api.registeredAssetIDs == Set(fixture.assets.map { $0.id.description }))
        for (index, asset) in fixture.assets.enumerated() {
            let entry = try #require(try await manifest.entry(for: asset.id))
            #expect(entry.state == .registered)
            #expect(try Data(contentsOf: fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory)) == before[index])
        }
    }

    @Test("Progress is emitted only after every durable state transition")
    func emitsDurableStateProgress() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let recorder = MigrationProgressRecorder()
        let coordinator = FixtureMigrationCoordinator(
            authorization: try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL),
            catalog: fixture.catalog,
            originalsURL: fixture.originalsURL,
            manifest: try MigrationManifestStore(databaseURL: fixture.rootURL.appending(path: "Sync/migration.sqlite", directoryHint: .notDirectory)),
            apiClient: InMemoryMigrationAPIClient(),
            progressHandler: { recorder.record($0) }
        )

        _ = try await coordinator.run()

        #expect(recorder.states == [.inventoried, .hashed, .uploaded, .verified, .registered])
    }

    @Test("A fixture run paginates past the catalog's 500-record page cap")
    func migratesMoreThanOneCatalogPage() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 501)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let manifest = try MigrationManifestStore(databaseURL: fixture.rootURL.appending(path: "Sync/migration.sqlite", directoryHint: .notDirectory))
        let coordinator = FixtureMigrationCoordinator(
            authorization: try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL),
            catalog: fixture.catalog,
            originalsURL: fixture.originalsURL,
            manifest: manifest,
            apiClient: InMemoryMigrationAPIClient()
        )

        let report = try await coordinator.run()

        #expect(report.registeredAssetIDs.count == 501)
    }

    @Test("A verified manifest entry resumes at asset registration without reuploading the blob")
    func resumesVerifiedEntryWithoutReuploading() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let asset = try #require(fixture.assets.first)
        let manifest = try MigrationManifestStore(databaseURL: fixture.rootURL.appending(path: "Sync/migration.sqlite", directoryHint: .notDirectory))
        let digest = try await FileDigestService().digest(at: fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory))
        let r2Key = "blobs/\(digest.sha256).jpg"
        try await manifest.upsert(MigrationManifestEntry(
            assetID: asset.id,
            storageKey: asset.storageKey.rawValue,
            byteSize: digest.byteSize,
            sha256: digest.sha256,
            remoteBlobID: digest.sha256,
            remoteR2Key: r2Key,
            remoteAssetID: nil,
            state: .verified,
            retryCount: 0,
            lastError: nil
        ))
        let api = InMemoryMigrationAPIClient()
        let coordinator = FixtureMigrationCoordinator(
            authorization: try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL),
            catalog: fixture.catalog,
            originalsURL: fixture.originalsURL,
            manifest: manifest,
            apiClient: api
        )

        let report = try await coordinator.run()

        #expect(report.registeredAssetIDs == [asset.id])
        #expect(api.initiateCallCount == 0)
        #expect(api.uploadCallCount == 0)
        #expect(api.completeCallCount == 0)
        #expect(api.registerCallCount == 1)
    }

    @Test("An uploaded manifest entry resumes at remote verification without reuploading the blob")
    func resumesUploadedEntryWithoutReuploading() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let asset = try #require(fixture.assets.first)
        let manifest = try MigrationManifestStore(databaseURL: fixture.rootURL.appending(path: "Sync/migration.sqlite", directoryHint: .notDirectory))
        let digest = try await FileDigestService().digest(at: fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory))
        try await manifest.upsert(MigrationManifestEntry(
            assetID: asset.id,
            storageKey: asset.storageKey.rawValue,
            byteSize: digest.byteSize,
            sha256: digest.sha256,
            remoteBlobID: digest.sha256,
            remoteR2Key: "blobs/\(digest.sha256).jpg",
            remoteAssetID: nil,
            state: .uploaded,
            retryCount: 0,
            lastError: nil
        ))
        let api = InMemoryMigrationAPIClient()
        let coordinator = FixtureMigrationCoordinator(
            authorization: try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL),
            catalog: fixture.catalog,
            originalsURL: fixture.originalsURL,
            manifest: manifest,
            apiClient: api
        )

        let report = try await coordinator.run()

        #expect(report.registeredAssetIDs == [asset.id])
        #expect(api.initiateCallCount == 0)
        #expect(api.uploadCallCount == 0)
        #expect(api.completeCallCount == 1)
        #expect(api.registerCallCount == 1)
    }

    @Test("An upload failure records a retryable manifest error and leaves local originals unchanged")
    func recordsUploadFailureThenRetries() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let asset = try #require(fixture.assets.first)
        let originalURL = fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory)
        let before = try Data(contentsOf: originalURL)
        let manifest = try MigrationManifestStore(databaseURL: fixture.rootURL.appending(path: "Sync/migration.sqlite", directoryHint: .notDirectory))
        let api = InMemoryMigrationAPIClient(failUploadCount: 1)
        let progress = MigrationProgressRecorder()
        let coordinator = FixtureMigrationCoordinator(
            authorization: try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL),
            catalog: fixture.catalog,
            originalsURL: fixture.originalsURL,
            manifest: manifest,
            apiClient: api,
            progressHandler: { progress.record($0) }
        )

        await #expect(throws: APIClientError.self) { try await coordinator.run() }
        let failed = try #require(try await manifest.entry(for: asset.id))
        #expect(failed.state == .failed)
        #expect(failed.retryCount == 1)
        #expect(failed.lastError == "injected fixture upload failure")
        #expect(progress.states == [.inventoried, .hashed, .failed])
        #expect(try Data(contentsOf: originalURL) == before)

        let report = try await coordinator.run()
        let completed = try #require(try await manifest.entry(for: asset.id))
        #expect(report.registeredAssetIDs == [asset.id])
        #expect(completed.state == .registered)
        #expect(completed.retryCount == 1)
        #expect(try Data(contentsOf: originalURL) == before)
    }

    @Test("Cancelling an active upload records an incomplete state without changing the original")
    func recordsCancellationWithoutChangingOriginal() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let asset = try #require(fixture.assets.first)
        let originalURL = fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory)
        let before = try Data(contentsOf: originalURL)
        let manifest = try MigrationManifestStore(databaseURL: fixture.rootURL.appending(path: "Sync/migration.sqlite", directoryHint: .notDirectory))
        let api = InMemoryMigrationAPIClient(uploadDelayNanoseconds: 5_000_000_000)
        let progress = MigrationProgressRecorder()
        let coordinator = FixtureMigrationCoordinator(
            authorization: try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL),
            catalog: fixture.catalog,
            originalsURL: fixture.originalsURL,
            manifest: manifest,
            apiClient: api,
            progressHandler: { progress.record($0) }
        )
        let task = Task { try await coordinator.run() }
        while !api.uploadHasStarted { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = try #require(try await manifest.entry(for: asset.id))
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.retryCount == 1)
        #expect(progress.states == [.inventoried, .hashed, .cancelled])
        #expect(try Data(contentsOf: originalURL) == before)
    }
}
