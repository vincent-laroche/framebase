import Testing
import Foundation
import FramebaseAPIClient
import FramebaseCatalog
import FramebaseDomain
import FramebaseMedia
@testable import FramebaseSync

@Suite("Framebase sync")
struct FramebaseSyncTests {
    @Test("A missing local original names the safe failure")
    func missingOriginalFailure() {
        let error = FramebaseSyncError.originalUnavailable(try! AssetStorageKey("ab/original.jpg"))
        #expect(error.errorDescription?.contains("Local original") == true)
    }

    @Test("A 5,000-asset non-personal fixture migrates and rebuilds with identity parity")
    func fiveThousandAssetMigrationAndRebuild() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let sourceCatalog = try CatalogDatabase(catalogURL: fixture.root.appending(path: "source.sqlite"))
        let store = try FixtureBlobStore(root: fixture.root.appending(path: "originals", directoryHint: .isDirectory))
        let rootFolder = try await sourceCatalog.folders.createFolder(named: FolderName("Fixture root"), in: nil)
        let childFolder = try await sourceCatalog.folders.createFolder(named: FolderName("Fixture child"), in: rootFolder.id)
        let assets = try await fixture.makeAssets(
            count: 5_000, parentIDs: [sourceCatalog.inboxID, rootFolder.id, childFolder.id], store: store
        )
        try await sourceCatalog.insertAssets(assets)
        let album = try await sourceCatalog.createAlbum(named: "Fixture album")
        try await sourceCatalog.albums.addAssets(Set(assets.prefix(500).map(\.id)), to: album.id)

        let api = FixtureSyncAPI()
        let sourceSync = FramebaseSync(catalog: sourceCatalog, blobStore: store, api: api)
        _ = try await sourceSync.prepareMigrationManifest()
        _ = try await sourceSync.hashPendingOriginals()
        try await sourceSync.uploadVerifiedLocalBlobs()
        try await sourceSync.publishInitialCatalog()
        try await sourceSync.reconcileRemoteCatalog()

        #expect(try await sourceCatalog.assets.count(matching: AssetQuery(scope: .allAssets)) == 5_000)
        #expect(try await sourceCatalog.cloud.status().mode == .cloudBacked)
        #expect(try await sourceCatalog.cloud.cloudState(for: assets[2_500].id)?.remoteRevision == 1)
        #expect(try await sourceCatalog.cloud.remoteRevision(entityType: "folder", entityID: rootFolder.id.description) == 1)
        #expect(try await sourceCatalog.cloud.remoteRevision(entityType: "album", entityID: album.id.description) == 2)
        #expect(try await store.fileCount() == 5_000)

        let rebuilt = try CatalogDatabase(catalogURL: fixture.root.appending(path: "rebuilt.sqlite"))
        let rebuiltStore = try FixtureBlobStore(root: fixture.root.appending(path: "rebuilt-originals", directoryHint: .isDirectory))
        let rebuildSync = FramebaseSync(catalog: rebuilt, blobStore: rebuiltStore, api: api)
        try await rebuildSync.reconcileRemoteCatalog()

        #expect(try await rebuilt.assets.count(matching: AssetQuery(scope: .allAssets)) == 5_000)
        #expect(try await rebuilt.folders.treeSnapshot().folders.count == 3)
        #expect(try await rebuilt.albums.albums().count == 1)
        #expect(try await rebuilt.assets.count(matching: AssetQuery(scope: .album(album.id))) == 500)
        let rebuiltIDs = try await rebuilt.assets.orderedIDs(matching: AssetQuery(scope: .allAssets), sortedBy: .defaultSort)
        #expect(Set(rebuiltIDs) == Set(assets.map(\.id)))
        let rebuiltSample = try #require(try await rebuilt.assets.asset(id: assets[2_500].id))
        #expect(rebuiltSample.storageKey == assets[2_500].storageKey)
        #expect(rebuiltSample.displayName == assets[2_500].displayName)
        #expect(try await rebuilt.cloud.cloudState(for: assets[2_500].id)?.remoteRevision == 1)
        #expect(try await rebuilt.cloud.remoteRevision(entityType: "folder", entityID: childFolder.id.description) == 1)
        #expect(try await rebuilt.cloud.remoteRevision(entityType: "album", entityID: album.id.description) == 2)
        #expect(try await rebuilt.assets.page(matching: AssetQuery(scope: .allAssets), sortedBy: .defaultSort, offset: 0, limit: 1).records.first?.originalAvailable == false)
    }

    @Test("Interrupted initial migration resumes idempotently without duplicate assets")
    func interruptedMigrationResumes() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let catalog = try CatalogDatabase(catalogURL: fixture.root.appending(path: "resume.sqlite"))
        let store = try FixtureBlobStore(root: fixture.root.appending(path: "resume-originals", directoryHint: .isDirectory))
        let assets = try await fixture.makeAssets(count: 100, parentIDs: [catalog.inboxID], store: store)
        try await catalog.insertAssets(assets)
        let api = FixtureSyncAPI()
        await api.failNextMutation()
        let sync = FramebaseSync(catalog: catalog, blobStore: store, api: api)
        _ = try await sync.prepareMigrationManifest()
        _ = try await sync.hashPendingOriginals()
        try await sync.uploadVerifiedLocalBlobs()
        do {
            try await sync.publishInitialCatalog()
            Issue.record("The interrupted migration should retain a failed outbox entry.")
        } catch let error as FramebaseSyncError {
            guard case .outboxNotDrained = error else { throw error }
        }

        try await sync.drainOutbox(now: Date().addingTimeInterval(2))
        try await sync.consumeChanges()
        try await sync.reconcileRemoteCatalog()

        #expect(await api.entityCount() == 100)
        #expect(try await catalog.cloud.status().pendingOutboxCount == 0)
        #expect(try await catalog.assets.count(matching: AssetQuery(scope: .allAssets)) == 100)
    }

    @Test("Tag and saved-search edits persist typed idempotent outbox payloads before any network attempt")
    func organizationOutboxPayloads() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let catalog = try CatalogDatabase(catalogURL: fixture.root.appending(path: "organization.sqlite"))
        let store = try FixtureBlobStore(root: fixture.root.appending(path: "organization-originals", directoryHint: .isDirectory))
        let sync = FramebaseSync(catalog: catalog, blobStore: store, api: FixtureSyncAPI())
        let tag = try await catalog.tags.createTag(named: TagName("status:review"))
        let search = SavedSearch(name: try SavedSearchName("Needs Review"), filter: AssetFilter(tagIDs: [tag.id]))
        let album = try await catalog.albums.createAlbum(named: "Review set")
        let exportReceipt = AssetExportReceipt(manifestSHA256: String(repeating: "b", count: 64), assetIDs: [])
        let backupManifest = BackupManifest(manifestSHA256: String(repeating: "c", count: 64))
        try await catalog.savedSearches.save(search)

        try await sync.enqueueTagMutation(.create(tag))
        try await sync.enqueueSavedSearchMutation(.save(search))
        try await sync.enqueueAlbumMutation(.create(album))
        try await sync.enqueueExportReceiptMutation(.record(exportReceipt))
        try await sync.enqueueBackupManifestMutation(.record(backupManifest))
        let entries = try await catalog.cloud.dueOutboxEntries()
        #expect(Set(entries.map(\.operation)) == ["create_tag", "create_saved_search", "create_album", "record_export_receipt", "record_backup_manifest"])
        let first = try #require(JSONSerialization.jsonObject(with: entries.first { $0.operation == "create_tag" }!.payload) as? [String: Any])
        let second = try #require(JSONSerialization.jsonObject(with: entries.first { $0.operation == "create_saved_search" }!.payload) as? [String: Any])
        #expect(((first["operations"] as? [[String: Any]])?.first?["payload"] as? [String: Any])?["name"] as? String == "status:review")
        #expect(((second["operations"] as? [[String: Any]])?.first?["payload"] as? [String: Any])?["name"] as? String == "Needs Review")
    }

    @Test("A remote organization deletion is applied from the change feed before snapshot reconciliation")
    func organizationDeletionFromChangeFeed() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let catalog = try CatalogDatabase(catalogURL: fixture.root.appending(path: "tombstone.sqlite"))
        let store = try FixtureBlobStore(root: fixture.root.appending(path: "tombstone-originals", directoryHint: .isDirectory))
        let tag = try await catalog.tags.createTag(named: TagName("status:review"))
        let api = FixtureSyncAPI()
        try await api.deleteOrganizationEntity(type: "tag", id: tag.id.description, revision: 4)

        try await FramebaseSync(catalog: catalog, blobStore: store, api: api).consumeChanges()

        #expect(try await catalog.tags.tags().isEmpty)
        #expect(try await catalog.cloud.remoteRevision(entityType: "tag", entityID: tag.id.description) == 4)
    }

    @Test("Export and backup receipt records reconcile from the authoritative bootstrap")
    func receiptBootstrapReconciliation() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let catalog = try CatalogDatabase(catalogURL: fixture.root.appending(path: "receipts.sqlite"))
        let store = try FixtureBlobStore(root: fixture.root.appending(path: "receipt-originals", directoryHint: .isDirectory))
        let exportID = ExportReceiptID()
        let backupID = BackupManifestID()
        let api = FixtureSyncAPI()
        let exportPayload = try JSONSerialization.data(withJSONObject: [
            "id": exportID.description, "manifestSHA256": String(repeating: "a", count: 64),
            "assetIds": [], "completedAt": "2026-08-10T00:00:00Z"
        ])
        let backupPayload = try JSONSerialization.data(withJSONObject: [
            "id": backupID.description, "manifestSHA256": String(repeating: "b", count: 64),
            "recordedAt": "2026-08-10T00:00:00Z", "lastRestoreDrillAt": "2026-08-10T01:00:00Z", "lastRestoreDrillResult": "passed"
        ])
        await api.seedRemoteEntity(RemoteCatalogEntity(
            entityType: "export_receipt", entityID: exportID.description, revision: 3,
            payload: exportPayload
        ))
        await api.seedRemoteEntity(RemoteCatalogEntity(
            entityType: "backup_manifest", entityID: backupID.description, revision: 4,
            payload: backupPayload
        ))

        try await FramebaseSync(catalog: catalog, blobStore: store, api: api).reconcileRemoteCatalog()

        #expect(try await catalog.exports.receipts().first?.id == exportID)
        #expect(try await catalog.backups.manifests().first?.id == backupID)
        #expect(try await catalog.backups.manifests().first?.lastRestoreDrillResult == "passed")
    }

    @Test("An export receipt survives an offline outbox retry without duplicating remote evidence")
    func exportReceiptOfflineRetry() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let catalog = try CatalogDatabase(catalogURL: fixture.root.appending(path: "receipt-retry.sqlite"))
        let store = try FixtureBlobStore(root: fixture.root.appending(path: "receipt-retry-originals", directoryHint: .isDirectory))
        let receipt = AssetExportReceipt(manifestSHA256: String(repeating: "d", count: 64), assetIDs: [])
        try await catalog.exports.record(receipt)
        let api = FixtureSyncAPI()
        let sync = FramebaseSync(catalog: catalog, blobStore: store, api: api)
        try await sync.enqueueExportReceiptMutation(.record(receipt))
        await api.failNextMutation()

        try await sync.drainOutbox()
        #expect(try await catalog.cloud.status().pendingOutboxCount == 1)
        #expect(await api.entityCount() == 0)

        try await sync.drainOutbox(now: Date().addingTimeInterval(2))
        #expect(try await catalog.cloud.status().pendingOutboxCount == 0)
        #expect(await api.entityCount() == 1)
    }
}

private final class SyncFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FramebaseSyncFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func makeAssets(count: Int, parentIDs: [FolderID], store: FixtureBlobStore) async throws -> [Asset] {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var result: [Asset] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let id = AssetID()
            let storageKey = try AssetStorageKey("\(id.description.prefix(2))/\(id.description).fixture")
            let bytes = Data("framebase-fixture-\(index)".utf8)
            try await store.write(bytes, for: storageKey)
            result.append(Asset(
                id: id, filename: "fixture-\(index).fixture", displayName: "Fixture \(index)",
                parentFolderID: parentIDs[index % parentIDs.count], storageKey: storageKey, fileSize: Int64(bytes.count),
                createdAt: date, modifiedAt: date, importedAt: date, updatedAt: date
            ))
        }
        return result
    }
}

private actor FixtureBlobStore: AssetBlobStore {
    private let root: URL

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ data: Data, for key: AssetStorageKey) throws {
        let url = root.appending(path: key.rawValue)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func fileCount() throws -> Int {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { count += 1 }
        }
        return count
    }

    func stage(sourceURL: URL, for assetID: AssetID) async throws -> StagedBlob { throw CocoaError(.fileWriteUnknown) }
    func commit(_ stagedBlob: StagedBlob) async throws -> CommittedBlob { throw CocoaError(.fileWriteUnknown) }
    func resolve(_ storageKey: AssetStorageKey) async throws -> URL { root.appending(path: storageKey.rawValue) }
    func validate(_ storageKey: AssetStorageKey) async -> Bool { FileManager.default.fileExists(atPath: root.appending(path: storageKey.rawValue).path) }
    func removeNewlyCommitted(_ committedBlob: CommittedBlob) async throws { throw CocoaError(.fileWriteUnknown) }
    func recoverStaging() async throws -> StagingRecoveryResult { StagingRecoveryResult(recoveredCount: 0) }
}

private actor FixtureSyncAPI: FramebaseSyncAPI {
    private var blobs: [String: RemoteBlobIntent] = [:]
    private var entities: [String: RemoteCatalogEntity] = [:]
    private var shouldFailNextMutation = false
    private var changeEvents: [RemoteChangeEvent] = []

    func failNextMutation() { shouldFailNextMutation = true }
    func entityCount() -> Int { entities.count }

    func deleteOrganizationEntity(type: String, id: String, revision: Int64) throws {
        entities.removeValue(forKey: id)
        changeEvents.append(RemoteChangeEvent(
            revision: revision,
            entityType: type,
            entityID: id,
            operation: "delete_\(type)",
            payload: try JSONSerialization.data(withJSONObject: ["id": id, "deleted": true, "revision": revision]),
            actorID: "fixture"
        ))
    }

    func seedRemoteEntity(_ entity: RemoteCatalogEntity) {
        entities[entity.entityID] = entity
    }

    func initiateUpload(_ intent: RemoteBlobIntent) async throws -> UploadInitiation {
        blobs[intent.sha256] = intent
        return UploadInitiation(status: "already_verified", blobID: intent.sha256)
    }

    func applyMutation(payload: Data, idempotencyKey: String) async throws -> Data {
        if shouldFailNextMutation {
            shouldFailNextMutation = false
            throw URLError(.networkConnectionLost)
        }
        let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let operations = try #require(root["operations"] as? [[String: Any]])
        for operation in operations {
            let type = try #require(operation["type"] as? String)
            let id = try #require(operation["targetId"] as? String)
            let values = try #require(operation["payload"] as? [String: Any])
            switch type {
            case "create_folder":
                let body: [String: Any] = [
                    "id": id, "name": try #require(values["name"] as? String),
                    "parentId": values["parentId"] ?? NSNull(), "sortOrder": 1_024
                ]
                entities[id] = RemoteCatalogEntity(entityType: "folder", entityID: id, revision: 1, payload: try JSONSerialization.data(withJSONObject: body))
            case "create_asset":
                let blobID = try #require(values["blobId"] as? String)
                let blob = try #require(blobs[blobID])
                let body: [String: Any] = [
                    "id": id, "blobId": blobID,
                    "displayName": try #require(values["displayName"] as? String),
                    "folderId": try #require(values["folderId"] as? String),
                    "favorite": false, "rating": 0,
                    "assetMetadata": try #require(values["assetMetadata"]),
                    "blob": ["sha256": blob.sha256, "byteSize": blob.byteSize, "mediaType": blob.mediaType, "originalExtension": blob.originalExtension]
                ]
                entities[id] = RemoteCatalogEntity(entityType: "asset", entityID: id, revision: 1, payload: try JSONSerialization.data(withJSONObject: body))
            case "create_album":
                let body: [String: Any] = ["id": id, "name": try #require(values["name"] as? String), "assetIds": []]
                entities[id] = RemoteCatalogEntity(entityType: "album", entityID: id, revision: 1, payload: try JSONSerialization.data(withJSONObject: body))
            case "add_assets_to_album":
                let current = try #require(entities[id])
                var body = try #require(JSONSerialization.jsonObject(with: current.payload) as? [String: Any])
                body["assetIds"] = try #require(values["assetIds"] as? [Any])
                entities[id] = RemoteCatalogEntity(entityType: "album", entityID: id, revision: 2, payload: try JSONSerialization.data(withJSONObject: body))
            case "record_export_receipt":
                let body: [String: Any] = [
                    "id": id, "manifestSHA256": try #require(values["manifestSHA256"] as? String),
                    "assetIds": values["assetIds"] ?? [], "completedAt": "2026-08-10T00:00:00Z"
                ]
                entities[id] = RemoteCatalogEntity(entityType: "export_receipt", entityID: id, revision: 1, payload: try JSONSerialization.data(withJSONObject: body))
            case "record_backup_manifest":
                let body: [String: Any] = [
                    "id": id, "manifestSHA256": try #require(values["manifestSHA256"] as? String),
                    "recordedAt": "2026-08-10T00:00:00Z", "lastRestoreDrillAt": NSNull(), "lastRestoreDrillResult": NSNull()
                ]
                entities[id] = RemoteCatalogEntity(entityType: "backup_manifest", entityID: id, revision: 1, payload: try JSONSerialization.data(withJSONObject: body))
            default:
                throw FramebaseAPIError(statusCode: 422, code: "UNSUPPORTED_FIXTURE_OPERATION", message: type)
            }
        }
        return Data("{}".utf8)
    }

    func bootstrapCatalog(cursor: String?) async throws -> CatalogBootstrapPage {
        CatalogBootstrapPage(watermarkRevision: changeEvents.map(\.revision).max() ?? 0, entities: entities.values.sorted { $0.entityID < $1.entityID })
    }

    func changes(after cursor: Int64) async throws -> ChangeFeedPage {
        ChangeFeedPage(events: changeEvents.filter { $0.revision > cursor }.sorted { $0.revision < $1.revision })
    }
    func upload(_ data: Data, using capability: DirectTransferCapability) async throws { throw CocoaError(.fileWriteUnknown) }
    func completeUpload(sha256: String, byteSize: Int64) async throws { throw CocoaError(.fileWriteUnknown) }
    func initiateMultipartUpload(_ intent: RemoteBlobIntent) async throws -> MultipartUploadInitiation { throw CocoaError(.fileWriteUnknown) }
    func uploadMultipartPart(_ data: Data, uploadID: String, partNumber: Int) async throws -> MultipartUploadedPart { throw CocoaError(.fileWriteUnknown) }
    func completeMultipartUpload(uploadID: String) async throws -> MultipartUploadCompletion { throw CocoaError(.fileWriteUnknown) }
    func verificationDownloadCapability(blobID: String) async throws -> DirectTransferCapability { throw CocoaError(.fileWriteUnknown) }
    func confirmMultipartUpload(uploadID: String, sha256: String, byteSize: Int64) async throws { throw CocoaError(.fileWriteUnknown) }
    func downloadCapability(blobID: String) async throws -> DirectTransferCapability { throw CocoaError(.fileWriteUnknown) }
    func downloadSHA256(_ capability: DirectTransferCapability) async throws -> (sha256: String, byteSize: Int64) { throw CocoaError(.fileWriteUnknown) }
    func downloadToTemporaryFile(_ capability: DirectTransferCapability) async throws -> TemporaryDownload { throw CocoaError(.fileWriteUnknown) }
}
