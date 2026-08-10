import CryptoKit
import Foundation
import FramebaseAPIClient
import FramebaseCatalog
import FramebaseDomain
import FramebaseMedia
import UniformTypeIdentifiers

public enum FramebaseSyncError: Error, LocalizedError, Sendable {
    case originalUnavailable(AssetStorageKey)
    case blobIdentityChanged(AssetID)
    case remoteVerificationFailed(String)
    case albumsRequireReconciliation(Int)
    case outboxNotDrained(Int)
    case remoteCatalogChangedDuringReconciliation
    case materializationUnavailable
    case conflictResolutionUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .originalUnavailable(key): "Local original is unavailable for \(key.rawValue)."
        case let .blobIdentityChanged(assetID): "The local original for \(assetID.description) changed after migration inventory."
        case let .remoteVerificationFailed(digest): "The remote blob \(digest) could not be verified."
        case let .albumsRequireReconciliation(count): "\(count) local album(s) require membership reconciliation before cloud backing can be enabled."
        case let .outboxNotDrained(count): "\(count) cloud mutation(s) remain pending or failed."
        case .remoteCatalogChangedDuringReconciliation: "The remote catalog kept changing during reconciliation; sync will retry safely."
        case .materializationUnavailable: "This library storage cannot safely materialize a remote original."
        case let .conflictResolutionUnavailable(operation): "Framebase cannot safely resolve the conflicted \(operation) operation."
        }
    }
}

public struct SyncDiagnostic: Hashable, Codable, Sendable {
    public let uploadedBlobCount: Int
    public let verifiedBlobCount: Int
    public let pendingOutboxCount: Int
    public let conflictCount: Int
    public let lastError: String?
}

/// A post-migration edit that can be expressed against one immutable remote
/// asset revision. Folder and album operations retain separate dependency and
/// conflict rules, so they are deliberately not smuggled through this API.
public enum CloudAssetMutation: Sendable {
    case move(to: FolderID)
    case favorite(Bool)
    case rating(AssetRating)
    case rename(displayName: String)
    case trash(retentionDays: Int)
    case restore
}

public enum CloudFolderMutation: Sendable {
    case create(Folder)
    case rename(Folder)
    case move(Folder)
}

public enum CloudTagMutation: Sendable {
    case create(Tag)
    case rename(Tag)
    case add(Tag, assetIDs: Set<AssetID>)
    case remove(Tag, assetIDs: Set<AssetID>)
    case delete(TagID)
}

public enum CloudSavedSearchMutation: Sendable {
    case save(SavedSearch)
    case delete(SavedSearchID)
}

public enum CloudAlbumMutation: Sendable {
    case create(Album)
    case rename(Album)
    case add(albumID: AlbumID, assetIDs: Set<AssetID>)
    case remove(albumID: AlbumID, assetIDs: Set<AssetID>)
    case reorder(Album, after: AlbumID?)
    case delete(AlbumID)
}

public enum CloudExportReceiptMutation: Sendable {
    case record(AssetExportReceipt)
}

public enum CloudBackupManifestMutation: Sendable {
    case record(BackupManifest)
    case recordRestoreDrill(manifestID: BackupManifestID, result: String)
}

/// Serializes cloud work for one local library. Local catalog work is durable
/// before every network operation, so cancellation/restart leaves either a
/// resumable record or a verified local original, never an ambiguous state.
public actor FramebaseSync {
    private let catalog: CatalogDatabase
    private let blobStore: any AssetBlobStore
    private let api: any FramebaseSyncAPI
    private let directUploadLimit: Int64

    public init(
        catalog: CatalogDatabase,
        blobStore: any AssetBlobStore,
        api: any FramebaseSyncAPI,
        directUploadLimit: Int64 = 20 * 1_024 * 1_024
    ) {
        self.catalog = catalog
        self.blobStore = blobStore
        self.api = api
        self.directUploadLimit = directUploadLimit
    }

    /// Captures immutable Phase 1 storage identity before hashing or upload.
    /// Re-running it is idempotent and never replaces an existing manifest row.
    public func prepareMigrationManifest() async throws -> [CloudMigrationManifestEntry] {
        try await catalog.cloud.updateStatus(mode: .preparingMigration, lastError: nil)
        return try await catalog.cloud.captureMigrationManifest()
    }

    /// Hashes missing manifest entries on this actor rather than the main actor.
    /// The file is read in bounded chunks to avoid loading original bytes into UI memory.
    public func hashPendingOriginals() async throws -> [CloudMigrationManifestEntry] {
        let manifest = try await catalog.cloud.migrationManifest()
        for entry in manifest where entry.sha256 == nil {
            let url = try await blobStore.resolve(entry.storageKey)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size == entry.byteSize else { throw FramebaseSyncError.blobIdentityChanged(entry.assetID) }
            let digest = try Self.sha256(of: url)
            try await catalog.cloud.recordHash(digest, for: entry.assetID)
            let blob = CloudBlob(
                sha256: digest,
                byteSize: entry.byteSize,
                mediaType: Self.mediaType(for: url),
                originalExtension: url.pathExtension.lowercased(),
                verificationState: .pendingUpload
            )
            try await catalog.cloud.upsertBlob(blob)
            try await catalog.cloud.associate(AssetCloudState(assetID: entry.assetID, blobSHA256: digest))
        }
        return try await catalog.cloud.migrationManifest()
    }

    /// Uploads each verified original through either the bounded direct path or
    /// the resumable multipart path. Both paths preserve the Phase 1 storage key
    /// and leave its managed local original in place after cloud verification.
    public func uploadVerifiedLocalBlobs() async throws {
        let manifest = try await catalog.cloud.migrationManifest()
        for entry in manifest {
            guard let sha256 = entry.sha256, let blob = try await catalog.cloud.blob(sha256: sha256) else { continue }
            guard blob.verificationState != .verified else { continue }

            try await catalog.cloud.upsertBlob(CloudBlob(
                sha256: blob.sha256, byteSize: blob.byteSize, mediaType: blob.mediaType,
                originalExtension: blob.originalExtension, remoteBlobID: blob.remoteBlobID,
                verificationState: .uploading
            ))
            do {
                let originalURL = try await blobStore.resolve(entry.storageKey)
                let localDigest = try Self.sha256(of: originalURL)
                guard localDigest == blob.sha256 else { throw FramebaseSyncError.blobIdentityChanged(entry.assetID) }
                let intent = RemoteBlobIntent(
                    sha256: blob.sha256, byteSize: blob.byteSize, mediaType: blob.mediaType, originalExtension: blob.originalExtension
                )
                let remoteBlobID: String
                if blob.byteSize <= directUploadLimit {
                    remoteBlobID = try await uploadDirect(intent: intent, originalURL: originalURL)
                } else {
                    remoteBlobID = try await uploadMultipart(intent: intent, originalURL: originalURL)
                }
                try await catalog.cloud.upsertBlob(CloudBlob(
                    sha256: blob.sha256, byteSize: blob.byteSize, mediaType: blob.mediaType,
                    originalExtension: blob.originalExtension, remoteBlobID: remoteBlobID,
                    verificationState: .verified, verifiedAt: .now
                ))
                try await catalog.cloud.associate(AssetCloudState(
                    assetID: entry.assetID, blobSHA256: blob.sha256,
                    materializationState: .localVerified
                ))
            } catch {
                try await catalog.cloud.upsertBlob(CloudBlob(
                    sha256: blob.sha256, byteSize: blob.byteSize, mediaType: blob.mediaType,
                    originalExtension: blob.originalExtension, remoteBlobID: blob.remoteBlobID,
                    verificationState: .failed, lastError: Self.safeError(error)
                ))
                try await catalog.cloud.updateStatus(mode: .paused, lastError: Self.safeError(error))
                throw error
            }
        }
    }

    /// Queues the initial remote catalog deterministically after all immutable
    /// blobs have verified. The local Inbox maps to the remote system Inbox;
    /// all other logical folder, asset, and album IDs stay byte-for-byte identical.
    public func publishInitialCatalog() async throws {
        let snapshot = try await catalog.folders.treeSnapshot()
        var queuedFolderIDs = Set<FolderID>()
        var remaining = snapshot.folders.filter { $0.systemKind == nil }
        while !remaining.isEmpty {
            let ready = remaining.filter { folder in
                folder.parentFolderID == nil || queuedFolderIDs.contains(folder.parentFolderID!)
            }
            guard !ready.isEmpty else { throw FramebaseSyncError.remoteVerificationFailed("folder hierarchy") }
            for folder in ready {
                try await enqueueMutation(
                    operation: "create_folder",
                    payload: try Self.mutationPayload(
                        idempotencyKey: "migration-folder-\(folder.id.description)",
                        type: "create_folder",
                        targetID: folder.id.description,
                        payload: ["name": .string(folder.name.rawValue), "parentId": folder.parentFolderID.map { .string($0.description) } ?? .null]
                    ),
                    idempotencyKey: "migration-folder-\(folder.id.description)"
                )
                queuedFolderIDs.insert(folder.id)
            }
            remaining.removeAll { queuedFolderIDs.contains($0.id) }
            try await drainOutbox()
            try await ensureOutboxDrained()
        }

        let assetIDs = try await catalog.assets.orderedIDs(matching: AssetQuery(scope: .allAssets), sortedBy: .defaultSort)
        for assetID in assetIDs {
            guard let asset = try await catalog.assets.asset(id: assetID),
                  let cloudState = try await catalog.cloud.cloudState(for: assetID),
                  let blob = try await catalog.cloud.blob(sha256: cloudState.blobSHA256),
                  blob.verificationState == .verified else {
                throw FramebaseSyncError.remoteVerificationFailed(assetID.description)
            }
            let remoteFolderID = asset.parentFolderID == snapshot.inboxID ? "system-inbox" : asset.parentFolderID.description
            let metadata = RemoteAssetMetadata(asset: asset)
            let key = "migration-asset-\(asset.id.description)"
            try await enqueueMutation(
                operation: "create_asset",
                payload: try Self.mutationPayload(
                    idempotencyKey: key,
                    type: "create_asset",
                    targetID: asset.id.description,
                    payload: [
                        "blobId": .string(cloudState.blobSHA256),
                        "folderId": .string(remoteFolderID),
                        "displayName": .string(asset.displayName),
                        "assetMetadata": try metadata.jsonValue()
                    ]
                ),
                idempotencyKey: key
            )
        }
        try await drainOutbox()
        try await ensureOutboxDrained()
        let albums = try await catalog.albums.albums()
        for album in albums {
            let key = "migration-album-\(album.id.description)"
            try await enqueueMutation(
                operation: "create_album",
                payload: try Self.mutationPayload(
                    idempotencyKey: key,
                    type: "create_album",
                    targetID: album.id.description,
                    payload: ["name": .string(album.name)]
                ),
                idempotencyKey: key
            )
        }
        try await drainOutbox()
        try await ensureOutboxDrained()
        for album in albums {
            let assetIDs = try await Self.assetIDs(in: album, catalog: catalog)
            guard !assetIDs.isEmpty else { continue }
            let key = "migration-album-members-\(album.id.description)"
            try await enqueueMutation(
                operation: "add_assets_to_album",
                payload: try Self.mutationPayload(
                    idempotencyKey: key,
                    type: "add_assets_to_album",
                    targetID: album.id.description,
                    payload: ["assetIds": .array(assetIDs.map { JSONValue.string($0.description) })],
                    baseRevision: 1
                ),
                idempotencyKey: key
            )
        }
        try await drainOutbox()
        try await ensureOutboxDrained()
        try await consumeChanges()
    }

    /// Rebuilds local catalog rows from the authoritative cloud snapshot. This
    /// is safe for both a clean catalog and a reconnecting catalog because IDs
    /// and storage keys are immutable and original availability is retained
    /// only when the local record still names the same managed file.
    public func reconcileRemoteCatalog() async throws {
        for _ in 0..<3 {
            var cursor: String?
            var watermark: Int64?
            var entities: [RemoteCatalogEntity] = []
            repeat {
                let page = try await api.bootstrapCatalog(cursor: cursor)
                watermark = watermark ?? page.watermarkRevision
                entities.append(contentsOf: page.entities)
                cursor = page.nextCursor
            } while cursor != nil
            guard let watermark else { continue }
            // A bounded retry turns the non-transactional paged endpoint into a
            // stable snapshot: any mutation that races a page appears after the
            // opening watermark, so this attempt is discarded before local SQL.
            if !(try await api.changes(after: watermark)).events.isEmpty { continue }

            let inboxID = catalog.inboxID
            var folders: [RemoteCatalogRecord] = []
            var assets: [RemoteCatalogRecord] = []
            var albums: [RemoteCatalogRecord] = []
            var tags: [RemoteCatalogRecord] = []
            var savedSearches: [RemoteCatalogRecord] = []
            var exportReceipts: [RemoteCatalogRecord] = []
            var backupManifests: [RemoteCatalogRecord] = []
            for entity in entities {
                switch entity.entityType {
                case "folder":
                    if let record = try Self.remoteFolder(entity, inboxID: inboxID) { folders.append(record) }
                case "asset":
                    assets.append(try Self.remoteAsset(entity, inboxID: inboxID))
                case "album":
                    albums.append(try Self.remoteAlbum(entity))
                case "tag":
                    tags.append(try Self.remoteTag(entity))
                case "saved_search":
                    savedSearches.append(try Self.remoteSavedSearch(entity))
                case "export_receipt":
                    exportReceipts.append(try Self.remoteExportReceipt(entity))
                case "backup_manifest":
                    backupManifests.append(try Self.remoteBackupManifest(entity))
                default:
                    continue
                }
            }
            var orderedFolders: [RemoteCatalogRecord] = []
            var pendingFolders = folders
            var emittedFolderIDs = Set<FolderID>()
            while !pendingFolders.isEmpty {
                let ready = pendingFolders.filter {
                    guard case let .folder(folder, _) = $0 else { return false }
                    return folder.parentFolderID == nil || emittedFolderIDs.contains(folder.parentFolderID!)
                }
                guard !ready.isEmpty else { throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_FOLDER", message: "Remote folder hierarchy contains a cycle or missing parent") }
                for record in ready {
                    if case let .folder(folder, _) = record { emittedFolderIDs.insert(folder.id) }
                }
                orderedFolders.append(contentsOf: ready)
                pendingFolders.removeAll { record in
                    guard case let .folder(folder, _) = record else { return false }
                    return emittedFolderIDs.contains(folder.id)
                }
            }
            try await catalog.cloud.applyRemoteRecords(orderedFolders + assets + albums + tags + savedSearches + exportReceipts + backupManifests)
            try await catalog.cloud.updateStatus(mode: .cloudBacked, changeCursor: watermark, lastSuccessfulSyncAt: .now, lastError: nil)
            return
        }
        throw FramebaseSyncError.remoteCatalogChangedDuringReconciliation
    }

    /// Recreates one missing managed original only after the private remote
    /// bytes are downloaded and SHA-256 verified. The temporary download never
    /// becomes catalog-visible; `ManagedAssetBlobStore` owns the final move.
    public func materializeOriginal(for assetID: AssetID) async throws -> URL {
        guard let state = try await catalog.cloud.cloudState(for: assetID),
              let blob = try await catalog.cloud.blob(sha256: state.blobSHA256),
              let asset = try await catalog.assets.asset(id: assetID),
              let materializingStore = blobStore as? any RemoteOriginalMaterializing else {
            throw FramebaseSyncError.materializationUnavailable
        }
        try await catalog.cloud.associate(AssetCloudState(
            assetID: assetID, blobSHA256: blob.sha256, remoteRevision: state.remoteRevision,
            materializationState: .materializing, lastError: nil
        ))
        do {
            let capability = try await api.downloadCapability(blobID: blob.remoteBlobID ?? blob.sha256)
            let download = try await api.downloadToTemporaryFile(capability)
            defer { try? FileManager.default.removeItem(at: download.fileURL) }
            guard download.sha256 == blob.sha256, download.byteSize == blob.byteSize else {
                throw FramebaseSyncError.remoteVerificationFailed(blob.sha256)
            }
            let location = try await materializingStore.materializeRemoteOriginal(
                from: download.fileURL, assetID: assetID, storageKey: asset.storageKey
            )
            try await catalog.setOriginalAvailable(true, for: assetID)
            try await catalog.cloud.associate(AssetCloudState(
                assetID: assetID, blobSHA256: blob.sha256, remoteRevision: state.remoteRevision,
                materializationState: .localVerified, lastError: nil
            ))
            return location
        } catch {
            try await catalog.cloud.associate(AssetCloudState(
                assetID: assetID, blobSHA256: blob.sha256, remoteRevision: state.remoteRevision,
                materializationState: .remoteOnly, lastError: Self.safeError(error)
            ))
            throw error
        }
    }

    private func uploadDirect(intent: RemoteBlobIntent, originalURL: URL) async throws -> String {
        let initiation = try await api.initiateUpload(intent)
        if initiation.status != "already_verified", let capability = initiation.upload {
            let data = try Data(contentsOf: originalURL, options: [.mappedIfSafe])
            guard Self.sha256(of: data) == intent.sha256 else { throw FramebaseSyncError.remoteVerificationFailed(intent.sha256) }
            try await api.upload(data, using: capability)
            try await api.completeUpload(sha256: intent.sha256, byteSize: intent.byteSize)
        }
        return initiation.blobID
    }

    private func uploadMultipart(intent: RemoteBlobIntent, originalURL: URL) async throws -> String {
        let initiation = try await api.initiateMultipartUpload(intent)
        if initiation.status == "already_verified" { return initiation.blobID }
        guard let uploadID = initiation.uploadID, let partByteSize = initiation.partByteSize, let partCount = initiation.partCount,
              partByteSize > 0, partCount > 0 else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_MULTIPART_RESPONSE", message: "API did not return a valid multipart manifest")
        }
        let uploadedPartNumbers = Set(initiation.uploadedParts.map(\.partNumber))
        let handle = try FileHandle(forReadingFrom: originalURL)
        defer { try? handle.close() }
        for partNumber in 1...partCount where !uploadedPartNumbers.contains(partNumber) {
            let offset = UInt64(partNumber - 1) * UInt64(partByteSize)
            try handle.seek(toOffset: offset)
            let expectedByteCount = partNumber == partCount
                ? Int(intent.byteSize - Int64(partByteSize) * Int64(partCount - 1))
                : partByteSize
            let data = try handle.read(upToCount: expectedByteCount) ?? Data()
            guard data.count == expectedByteCount else { throw FramebaseSyncError.remoteVerificationFailed(intent.sha256) }
            _ = try await api.uploadMultipartPart(data, uploadID: uploadID, partNumber: partNumber)
        }
        _ = try await api.completeMultipartUpload(uploadID: uploadID)
        let capability = try await api.verificationDownloadCapability(blobID: intent.sha256)
        let verification = try await api.downloadSHA256(capability)
        guard verification.sha256 == intent.sha256, verification.byteSize == intent.byteSize else {
            throw FramebaseSyncError.remoteVerificationFailed(intent.sha256)
        }
        try await api.confirmMultipartUpload(uploadID: uploadID, sha256: intent.sha256, byteSize: intent.byteSize)
        return initiation.blobID
    }

    public func enqueueMutation(operation: String, payload: Data, idempotencyKey: String = UUID().uuidString.lowercased()) async throws {
        try await catalog.cloud.appendOutbox(SyncOutboxEntry(idempotencyKey: idempotencyKey, operation: operation, payload: payload))
    }

    /// Persists cloud-backed asset edits in the outbox after their local
    /// transaction committed. Each item carries the remote revision observed
    /// during reconciliation, so a concurrent device edit becomes an explicit
    /// conflict rather than a last-writer-wins overwrite.
    public func enqueueAssetMutation(_ mutation: CloudAssetMutation, for assetIDs: Set<AssetID>) async throws {
        for assetID in assetIDs.sorted(by: { $0.description < $1.description }) {
            guard let asset = try await catalog.assets.asset(id: assetID),
                  let state = try await catalog.cloud.cloudState(for: assetID),
                  let revision = state.remoteRevision else {
                throw FramebaseSyncError.remoteVerificationFailed("missing remote revision for \(assetID.description)")
            }
            let type: String
            let payload: [String: JSONValue]
            switch mutation {
            case let .move(folderID):
                type = "move_asset"
                payload = ["folderId": .string(folderID.description)]
            case let .favorite(value):
                type = "update_favorite"
                payload = ["favorite": .bool(value)]
            case let .rating(value):
                type = "update_rating"
                payload = ["rating": .number(Double(value.rawValue))]
            case let .rename(displayName):
                type = "rename_asset"
                payload = ["displayName": .string(displayName)]
            case let .trash(retentionDays):
                type = "trash_asset"
                payload = ["retentionDays": .number(Double(retentionDays))]
            case .restore:
                type = "restore_asset"
                payload = [:]
            }
            let idempotencyKey = "asset-edit-\(asset.id.description)-\(UUID().uuidString.lowercased())"
            try await enqueueMutation(
                operation: type,
                payload: try Self.mutationPayload(
                    idempotencyKey: idempotencyKey,
                    type: type,
                    targetID: asset.id.description,
                    payload: payload,
                    baseRevision: revision
                ),
                idempotencyKey: idempotencyKey
            )
        }
    }

    /// Queues a committed logical-folder change with the remote revision that
    /// reconciliation recorded. The system Inbox is remote-owned and is never
    /// sent through this path.
    public func enqueueFolderMutation(_ mutation: CloudFolderMutation) async throws {
        let folder: Folder
        let type: String
        let baseRevision: Int64?
        let payload: [String: JSONValue]
        switch mutation {
        case let .create(value):
            folder = value
            type = "create_folder"
            baseRevision = nil
            payload = [
                "name": .string(folder.name.rawValue),
                "parentId": folder.parentFolderID.map { .string($0.description) } ?? .null
            ]
        case let .rename(value):
            folder = value
            type = "rename_folder"
            baseRevision = try await remoteFolderRevision(for: folder)
            payload = ["name": .string(folder.name.rawValue)]
        case let .move(value):
            folder = value
            type = "move_folder"
            baseRevision = try await remoteFolderRevision(for: folder)
            payload = ["parentId": folder.parentFolderID.map { .string($0.description) } ?? .null]
        }
        guard folder.systemKind == nil else {
            throw FramebaseSyncError.remoteVerificationFailed("system folder mutation")
        }
        let idempotencyKey = "folder-edit-\(folder.id.description)-\(UUID().uuidString.lowercased())"
        try await enqueueMutation(
            operation: type,
            payload: try Self.mutationPayload(
                idempotencyKey: idempotencyKey,
                type: type,
                targetID: folder.id.description,
                payload: payload,
                baseRevision: baseRevision
            ),
            idempotencyKey: idempotencyKey
        )
    }

    /// Queues a locally committed tag edit after its typed remote revision has
    /// been reconciled. A newly created tag is deliberately sent before its
    /// membership operation, preserving the dependency through offline replay.
    public func enqueueTagMutation(_ mutation: CloudTagMutation) async throws {
        let type: String
        let targetID: String
        let baseRevision: Int64?
        let payload: [String: JSONValue]
        switch mutation {
        case let .create(tag):
            type = "create_tag"
            targetID = tag.id.description
            baseRevision = nil
            payload = ["name": .string(tag.name.rawValue)]
        case let .rename(tag):
            type = "rename_tag"
            targetID = tag.id.description
            baseRevision = try await remoteEntityRevision(type: "tag", id: tag.id.description)
            payload = ["name": .string(tag.name.rawValue)]
        case let .add(tag, assetIDs):
            type = "add_tag_to_assets"
            targetID = tag.id.description
            baseRevision = try await remoteEntityRevision(type: "tag", id: tag.id.description)
            payload = ["assetIds": .array(assetIDs.sorted { $0.description < $1.description }.map { .string($0.description) })]
        case let .remove(tag, assetIDs):
            type = "remove_tag_from_assets"
            targetID = tag.id.description
            baseRevision = try await remoteEntityRevision(type: "tag", id: tag.id.description)
            payload = ["assetIds": .array(assetIDs.sorted { $0.description < $1.description }.map { .string($0.description) })]
        case let .delete(tagID):
            type = "delete_tag"
            targetID = tagID.description
            baseRevision = try await remoteEntityRevision(type: "tag", id: tagID.description)
            payload = [:]
        }
        let key = "tag-edit-\(targetID)-\(UUID().uuidString.lowercased())"
        try await enqueueMutation(
            operation: type,
            payload: try Self.mutationPayload(idempotencyKey: key, type: type, targetID: targetID, payload: payload, baseRevision: baseRevision),
            idempotencyKey: key
        )
    }

    public func enqueueSavedSearchMutation(_ mutation: CloudSavedSearchMutation) async throws {
        let type: String
        let targetID: String
        let baseRevision: Int64?
        let payload: [String: JSONValue]
        switch mutation {
        case let .save(search):
            targetID = search.id.description
            let existingRevision = try await catalog.cloud.remoteRevision(entityType: "saved_search", entityID: targetID)
            type = existingRevision == nil ? "create_saved_search" : "update_saved_search"
            baseRevision = existingRevision
            payload = [
                "name": .string(search.name.rawValue),
                "rules": try Self.jsonValue(search.filter),
                "sort": try Self.jsonValue(search.sort)
            ]
        case let .delete(searchID):
            targetID = searchID.description
            type = "delete_saved_search"
            baseRevision = try await remoteEntityRevision(type: "saved_search", id: targetID)
            payload = [:]
        }
        let key = "saved-search-edit-\(targetID)-\(UUID().uuidString.lowercased())"
        try await enqueueMutation(
            operation: type,
            payload: try Self.mutationPayload(idempotencyKey: key, type: type, targetID: targetID, payload: payload, baseRevision: baseRevision),
            idempotencyKey: key
        )
    }

    /// Queues a locally committed album mutation. Membership is sent in small,
    /// deterministic batches by the caller; all existing albums carry their
    /// reconciled revision to make concurrent edits explicit conflicts.
    public func enqueueAlbumMutation(_ mutation: CloudAlbumMutation) async throws {
        let type: String
        let targetID: String
        let baseRevision: Int64?
        let payload: [String: JSONValue]
        switch mutation {
        case let .create(album):
            type = "create_album"
            targetID = album.id.description
            baseRevision = nil
            payload = ["name": .string(album.name)]
        case let .rename(album):
            type = "rename_album"
            targetID = album.id.description
            baseRevision = try await remoteEntityRevision(type: "album", id: targetID)
            payload = ["name": .string(album.name)]
        case let .add(albumID, assetIDs):
            type = "add_assets_to_album"
            targetID = albumID.description
            baseRevision = try await remoteEntityRevision(type: "album", id: targetID)
            payload = ["assetIds": .array(assetIDs.sorted { $0.description < $1.description }.map { .string($0.description) })]
        case let .remove(albumID, assetIDs):
            type = "remove_assets_from_album"
            targetID = albumID.description
            baseRevision = try await remoteEntityRevision(type: "album", id: targetID)
            payload = ["assetIds": .array(assetIDs.sorted { $0.description < $1.description }.map { .string($0.description) })]
        case let .reorder(album, predecessorID):
            type = "reorder_album"
            targetID = album.id.description
            baseRevision = try await remoteEntityRevision(type: "album", id: targetID)
            payload = ["predecessorId": predecessorID.map { .string($0.description) } ?? .null]
        case let .delete(albumID):
            type = "delete_album"
            targetID = albumID.description
            baseRevision = try await remoteEntityRevision(type: "album", id: targetID)
            payload = [:]
        }
        let key = "album-edit-\(targetID)-\(UUID().uuidString.lowercased())"
        try await enqueueMutation(
            operation: type,
            payload: try Self.mutationPayload(idempotencyKey: key, type: type, targetID: targetID, payload: payload, baseRevision: baseRevision),
            idempotencyKey: key
        )
    }

    public func enqueueExportReceiptMutation(_ mutation: CloudExportReceiptMutation) async throws {
        let receipt: AssetExportReceipt
        switch mutation { case let .record(value): receipt = value }
        let key = "export-receipt-\(receipt.id.description)-\(UUID().uuidString.lowercased())"
        try await enqueueMutation(
            operation: "record_export_receipt",
            payload: try Self.mutationPayload(
                idempotencyKey: key,
                type: "record_export_receipt",
                targetID: receipt.id.description,
                payload: [
                    "manifestSHA256": .string(receipt.manifestSHA256),
                    "assetIds": .array(receipt.assetIDs.sorted { $0.description < $1.description }.map { .string($0.description) }),
                    "completedAt": .string(ISO8601DateFormatter().string(from: receipt.completedAt))
                ],
                baseRevision: nil
            ),
            idempotencyKey: key
        )
    }

    public func enqueueBackupManifestMutation(_ mutation: CloudBackupManifestMutation) async throws {
        let type: String
        let targetID: String
        let baseRevision: Int64?
        let payload: [String: JSONValue]
        switch mutation {
        case let .record(manifest):
            type = "record_backup_manifest"
            targetID = manifest.id.description
            baseRevision = nil
            payload = ["manifestSHA256": .string(manifest.manifestSHA256)]
        case let .recordRestoreDrill(manifestID, result):
            let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.count <= 240 else {
                throw FramebaseSyncError.remoteVerificationFailed("invalid backup restore-drill result")
            }
            type = "record_backup_restore_drill"
            targetID = manifestID.description
            baseRevision = try await remoteEntityRevision(type: "backup_manifest", id: targetID)
            payload = ["result": .string(normalized)]
        }
        let key = "backup-manifest-\(targetID)-\(UUID().uuidString.lowercased())"
        try await enqueueMutation(
            operation: type,
            payload: try Self.mutationPayload(idempotencyKey: key, type: type, targetID: targetID, payload: payload, baseRevision: baseRevision),
            idempotencyKey: key
        )
    }

    /// Makes a best-effort network attempt without ever discarding a durable
    /// local mutation. Offline failures remain in the outbox for the next
    /// explicit sync session; only a drained queue advances the cursor.
    public func sendQueuedChanges() async throws {
        try await drainOutbox()
        let status = try await catalog.cloud.status()
        guard status.pendingOutboxCount == 0 else { return }
        try await consumeChanges()
    }

    /// Resolves an explicit revision conflict only after reloading the remote
    /// catalog. Keeping local re-bases a supported logical edit against the
    /// refreshed remote revision; keeping remote replaces the stale local
    /// replica. Neither branch touches immutable original bytes.
    public func resolveConflict(_ conflict: SyncConflict, as resolution: SyncConflictResolutionState) async throws {
        guard resolution == .keptLocal || resolution == .keptRemote else {
            throw FramebaseSyncError.conflictResolutionUnavailable(conflict.entityType)
        }
        let context = try Self.queuedMutationContext(from: conflict.localPayload)
        switch resolution {
        case .keptRemote:
            try await reconcileRemoteCatalog()
            try await catalog.cloud.resolveConflict(conflict.id, as: .keptRemote)
        case .keptLocal:
            switch context.type {
            case "update_favorite":
                let asset = try await localAsset(context.targetID)
                try await reconcileRemoteCatalog()
                try await enqueueAssetMutation(.favorite(asset.favorite), for: [asset.id])
            case "update_rating":
                let asset = try await localAsset(context.targetID)
                try await reconcileRemoteCatalog()
                try await enqueueAssetMutation(.rating(asset.rating), for: [asset.id])
            case "move_asset", "move_assets":
                let asset = try await localAsset(context.targetID)
                try await reconcileRemoteCatalog()
                try await enqueueAssetMutation(.move(to: asset.parentFolderID), for: [asset.id])
            case "rename_folder":
                let folder = try await localFolder(context.targetID)
                try await reconcileRemoteCatalog()
                try await enqueueFolderMutation(.rename(folder))
            case "move_folder":
                let folder = try await localFolder(context.targetID)
                try await reconcileRemoteCatalog()
                try await enqueueFolderMutation(.move(folder))
            default:
                throw FramebaseSyncError.conflictResolutionUnavailable(context.type)
            }
            try await sendQueuedChanges()
            try await catalog.cloud.resolveConflict(conflict.id, as: .keptLocal)
        default:
            throw FramebaseSyncError.conflictResolutionUnavailable(context.type)
        }
    }

    /// Adopts originals imported after the initial cutover. The import has
    /// already committed locally, so each stage is restartable: the manifest
    /// records identity first, upload verification precedes catalog creation,
    /// and a failed network attempt leaves the local original untouched.
    public func synchronizeImportedAssets(_ assetIDs: Set<AssetID>) async throws {
        guard !assetIDs.isEmpty else { return }
        _ = try await prepareMigrationManifest()
        _ = try await hashPendingOriginals()
        try await uploadVerifiedLocalBlobs()
        let snapshot = try await catalog.folders.treeSnapshot()
        for assetID in assetIDs.sorted(by: { $0.description < $1.description }) {
            try await enqueueAssetCreation(assetID, inboxID: snapshot.inboxID, idempotencyPrefix: "import-asset")
        }
        try await sendQueuedChanges()
    }

    private func remoteFolderRevision(for folder: Folder) async throws -> Int64 {
        guard let revision = try await catalog.cloud.remoteRevision(entityType: "folder", entityID: folder.id.description) else {
            throw FramebaseSyncError.remoteVerificationFailed("missing remote revision for \(folder.id.description)")
        }
        return revision
    }

    private func remoteEntityRevision(type: String, id: String) async throws -> Int64 {
        guard let revision = try await catalog.cloud.remoteRevision(entityType: type, entityID: id) else {
            throw FramebaseSyncError.remoteVerificationFailed("missing remote revision for \(id)")
        }
        return revision
    }

    private func localAsset(_ identifier: String) async throws -> Asset {
        guard let uuid = UUID(uuidString: identifier),
              let asset = try await catalog.assets.asset(id: AssetID(rawValue: uuid)) else {
            throw FramebaseSyncError.conflictResolutionUnavailable("asset")
        }
        return asset
    }

    private func localFolder(_ identifier: String) async throws -> Folder {
        guard let uuid = UUID(uuidString: identifier),
              let folder = try await catalog.folders.treeSnapshot().folders.first(where: { $0.id == FolderID(rawValue: uuid) }) else {
            throw FramebaseSyncError.conflictResolutionUnavailable("folder")
        }
        return folder
    }

    private static func queuedMutationContext(from payload: Data) throws -> QueuedMutationContext {
        let request = try JSONDecoder().decode(QueuedMutationRequest.self, from: payload)
        guard request.operations.count == 1 else { throw FramebaseSyncError.conflictResolutionUnavailable("batch") }
        return request.operations[0]
    }

    private func enqueueAssetCreation(_ assetID: AssetID, inboxID: FolderID, idempotencyPrefix: String) async throws {
        guard let asset = try await catalog.assets.asset(id: assetID),
              let cloudState = try await catalog.cloud.cloudState(for: assetID),
              let blob = try await catalog.cloud.blob(sha256: cloudState.blobSHA256),
              blob.verificationState == .verified else {
            throw FramebaseSyncError.remoteVerificationFailed(assetID.description)
        }
        let remoteFolderID = asset.parentFolderID == inboxID ? "system-inbox" : asset.parentFolderID.description
        let key = "\(idempotencyPrefix)-\(asset.id.description)"
        try await enqueueMutation(
            operation: "create_asset",
            payload: try Self.mutationPayload(
                idempotencyKey: key,
                type: "create_asset",
                targetID: asset.id.description,
                payload: [
                    "blobId": .string(cloudState.blobSHA256),
                    "folderId": .string(remoteFolderID),
                    "displayName": .string(asset.displayName),
                    "assetMetadata": try RemoteAssetMetadata(asset: asset).jsonValue()
                ]
            ),
            idempotencyKey: key
        )
    }

    public func drainOutbox(now: Date = .now) async throws {
        try await catalog.cloud.updateStatus(mode: .syncing, lastError: nil)
        while true {
            let entries = try await catalog.cloud.dueOutboxEntries(at: now)
            guard !entries.isEmpty else { return }
            for entry in entries {
                try await catalog.cloud.updateOutbox(id: entry.id, state: .inFlight, attemptCount: entry.attemptCount + 1, lastError: nil)
                do {
                    _ = try await api.applyMutation(payload: entry.payload, idempotencyKey: entry.idempotencyKey)
                    try await catalog.cloud.updateOutbox(id: entry.id, state: .applied, lastError: nil)
                } catch let error as FramebaseAPIError where error.isConflict {
                    let context = try? Self.queuedMutationContext(from: entry.payload)
                    try await catalog.cloud.recordConflict(SyncConflict(
                        entityType: context?.type ?? entry.operation,
                        entityID: context?.targetID ?? entry.id.uuidString.lowercased(),
                        localPayload: entry.payload,
                        remotePayload: try JSONEncoder().encode(RemoteConflictContext(code: error.code, message: error.message, requestID: error.requestID))
                    ))
                    try await catalog.cloud.updateOutbox(id: entry.id, state: .conflict, lastError: error.message)
                } catch {
                    let retry = now.addingTimeInterval(Self.retryDelay(attempt: entry.attemptCount + 1))
                    try await catalog.cloud.updateOutbox(
                        id: entry.id, state: .failed, attemptCount: entry.attemptCount + 1,
                        nextAttemptAt: retry, lastError: Self.safeError(error)
                    )
                }
            }
        }
    }

    /// Advances the cursor only after each page has been durably accepted. The
    /// current v1 feed has no destructive operations, so unknown event types
    /// are retained by revision without altering local Phase 1 entities.
    public func consumeChanges() async throws {
        var cursor = try await catalog.cloud.status().changeCursor
        var observedRemoteChanges = false
        var organizationTombstones: [RemoteChangeEvent] = []
        while true {
            let page = try await api.changes(after: cursor)
            guard !page.events.isEmpty else { break }
            for event in page.events {
                guard event.revision > cursor else { continue }
                observedRemoteChanges = true
                cursor = event.revision
                if ["album", "tag", "saved_search"].contains(event.entityType),
                   (try? JSONDecoder().decode(RemoteDeletionPayload.self, from: event.payload).deleted) == true {
                    organizationTombstones.append(event)
                }
            }
            try await catalog.cloud.updateStatus(mode: .syncing, changeCursor: cursor, lastError: nil)
            if page.nextCursor == nil { break }
        }
        if observedRemoteChanges {
            for tombstone in organizationTombstones.sorted(by: { $0.revision < $1.revision }) {
                try await catalog.cloud.applyRemoteDeletion(
                    entityType: tombstone.entityType,
                    entityID: tombstone.entityID,
                    revision: tombstone.revision
                )
            }
            try await reconcileRemoteCatalog()
        } else {
            try await catalog.cloud.updateStatus(mode: .cloudBacked, changeCursor: cursor, lastSuccessfulSyncAt: .now, lastError: nil)
        }
    }

    public func disableCloudBacking() async throws {
        try await catalog.cloud.updateStatus(mode: .localOnly, lastError: nil)
    }

    public func diagnostics() async throws -> SyncDiagnostic {
        let status = try await catalog.cloud.status()
        let manifest = try await catalog.cloud.migrationManifest()
        var verified = 0
        for entry in manifest where entry.sha256 != nil {
            if let blob = try await catalog.cloud.blob(sha256: entry.sha256!), blob.verificationState == .verified { verified += 1 }
        }
        return SyncDiagnostic(
            uploadedBlobCount: verified, verifiedBlobCount: verified,
            pendingOutboxCount: status.pendingOutboxCount, conflictCount: status.unresolvedConflictCount,
            lastError: status.lastError
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mediaType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType { return mime }
        return "application/octet-stream"
    }

    private static func retryDelay(attempt: Int) -> TimeInterval {
        min(pow(2, Double(max(0, attempt - 1))), 300)
    }

    private static func safeError(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }

    private static func remoteFolder(_ entity: RemoteCatalogEntity, inboxID: FolderID) throws -> RemoteCatalogRecord? {
        let payload = try JSONDecoder().decode(RemoteFolderPayload.self, from: entity.payload)
        if payload.id == "system-inbox" { return nil }
        guard let folderUUID = UUID(uuidString: payload.id) else { throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_FOLDER", message: "Remote folder ID is invalid") }
        let parentID: FolderID?
        if let parent = payload.parentID {
            guard parent != "system-inbox", let parentUUID = UUID(uuidString: parent) else {
                throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_FOLDER", message: "Remote folder parent is invalid")
            }
            parentID = FolderID(rawValue: parentUUID)
        } else {
            parentID = nil
        }
        return .folder(folder: Folder(
            id: FolderID(rawValue: folderUUID), name: try FolderName(payload.name), parentFolderID: parentID,
            createdAt: payload.createdAt?.date ?? .now, updatedAt: payload.updatedAt?.date ?? .now,
            sortOrder: Int64(payload.sortOrder ?? 0), systemKind: nil
        ), revision: entity.revision)
    }

    private static func remoteAsset(_ entity: RemoteCatalogEntity, inboxID: FolderID) throws -> RemoteCatalogRecord {
        let payload = try JSONDecoder().decode(RemoteAssetPayload.self, from: entity.payload)
        guard let assetUUID = UUID(uuidString: payload.id), let metadata = payload.assetMetadata,
              let mediaType = MediaType(rawValue: metadata.mediaType), payload.blob.sha256 == payload.blobID else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_ASSET", message: "Remote asset envelope is incomplete")
        }
        let folderID: FolderID
        if payload.folderID == "system-inbox" {
            folderID = inboxID
        } else if let folderUUID = UUID(uuidString: payload.folderID) {
            folderID = FolderID(rawValue: folderUUID)
        } else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_ASSET", message: "Remote asset folder is invalid")
        }
        let asset = Asset(
            id: AssetID(rawValue: assetUUID), filename: metadata.filename, displayName: payload.displayName,
            parentFolderID: folderID, storageKey: try AssetStorageKey(metadata.storageKey), mediaType: mediaType,
            width: metadata.width, height: metadata.height, fileSize: metadata.fileSize,
            createdAt: metadata.createdAt, modifiedAt: metadata.modifiedAt, importedAt: metadata.importedAt,
            updatedAt: .now, favorite: payload.favorite, rating: try AssetRating(payload.rating), metadata: metadata.metadata
        )
        let trashReceipt: AssetTrashReceipt?
        if payload.status == "trashed" {
            guard let trash = payload.trash,
                  let priorFolderUUID = UUID(uuidString: trash.priorFolderID) else {
                throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_TRASH", message: "Remote Trash receipt is incomplete")
            }
            trashReceipt = AssetTrashReceipt(
                assetID: asset.id,
                priorFolderID: FolderID(rawValue: priorFolderUUID),
                albumIDs: try trash.priorAlbumIDs.map { value in
                    guard let uuid = UUID(uuidString: value) else { throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_TRASH", message: "Remote Trash album ID is invalid") }
                    return AlbumID(rawValue: uuid)
                },
                tagIDs: try trash.priorTagIDs.map { value in
                    guard let uuid = UUID(uuidString: value) else { throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_TRASH", message: "Remote Trash tag ID is invalid") }
                    return TagID(rawValue: uuid)
                },
                trashedAt: trash.trashedAt.date,
                scheduledPurgeAt: trash.scheduledPurgeAt.date
            )
        } else {
            trashReceipt = nil
        }
        return .asset(asset: asset, blob: CloudBlob(
            sha256: payload.blob.sha256, byteSize: payload.blob.byteSize, mediaType: payload.blob.mediaType,
            originalExtension: payload.blob.originalExtension, remoteBlobID: payload.blob.sha256,
            verificationState: .verified, verifiedAt: .now
        ), trashReceipt: trashReceipt, revision: entity.revision)
    }

    private static func remoteAlbum(_ entity: RemoteCatalogEntity) throws -> RemoteCatalogRecord {
        let payload = try JSONDecoder().decode(RemoteAlbumPayload.self, from: entity.payload)
        guard let albumUUID = UUID(uuidString: payload.id) else { throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_ALBUM", message: "Remote album ID is invalid") }
        return .album(album: Album(
            id: AlbumID(rawValue: albumUUID), name: payload.name, createdAt: payload.createdAt?.date ?? .now,
            updatedAt: payload.updatedAt?.date ?? .now, sortOrder: Int64(payload.sortOrder ?? 1_024)
        ), assetIDs: try payload.assetIDs.map { value in
            guard let id = UUID(uuidString: value) else { throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_ALBUM", message: "Remote album asset ID is invalid") }
            return AssetID(rawValue: id)
        }, revision: entity.revision)
    }

    private static func remoteTag(_ entity: RemoteCatalogEntity) throws -> RemoteCatalogRecord {
        let payload = try JSONDecoder().decode(RemoteTagPayload.self, from: entity.payload)
        guard let tagUUID = UUID(uuidString: payload.id) else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_TAG", message: "Remote tag ID is invalid")
        }
        let tag = Tag(
            id: TagID(rawValue: tagUUID), name: try TagName(payload.name),
            createdAt: payload.createdAt?.date ?? .now, updatedAt: payload.updatedAt?.date ?? .now
        )
        let assetIDs = try payload.assetIDs.map { value -> AssetID in
            guard let uuid = UUID(uuidString: value) else {
                throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_TAG", message: "Remote tag asset ID is invalid")
            }
            return AssetID(rawValue: uuid)
        }
        return .tag(tag: tag, assetIDs: assetIDs, revision: entity.revision)
    }

    private static func remoteSavedSearch(_ entity: RemoteCatalogEntity) throws -> RemoteCatalogRecord {
        let payload = try JSONDecoder().decode(RemoteSavedSearchPayload.self, from: entity.payload)
        guard let uuid = UUID(uuidString: payload.id) else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_SAVED_SEARCH", message: "Remote saved-search ID is invalid")
        }
        return .savedSearch(
            search: SavedSearch(
                id: SavedSearchID(rawValue: uuid), name: try SavedSearchName(payload.name),
                filter: payload.rules, sort: payload.sort,
                createdAt: payload.createdAt?.date ?? .now, updatedAt: payload.updatedAt?.date ?? .now
            ),
            revision: entity.revision
        )
    }

    private static func remoteExportReceipt(_ entity: RemoteCatalogEntity) throws -> RemoteCatalogRecord {
        let payload = try JSONDecoder().decode(RemoteExportReceiptPayload.self, from: entity.payload)
        guard let receiptUUID = UUID(uuidString: payload.id),
              payload.manifestSHA256.count == 64,
              payload.manifestSHA256.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_EXPORT_RECEIPT", message: "Remote export receipt is invalid")
        }
        let assetIDs = try payload.assetIDs.map { value -> AssetID in
            guard let uuid = UUID(uuidString: value) else {
                throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_EXPORT_RECEIPT", message: "Remote export receipt asset ID is invalid")
            }
            return AssetID(rawValue: uuid)
        }
        return .exportReceipt(
            receipt: AssetExportReceipt(
                id: ExportReceiptID(rawValue: receiptUUID), manifestSHA256: payload.manifestSHA256,
                assetIDs: assetIDs, completedAt: payload.completedAt.date
            ),
            revision: entity.revision
        )
    }

    private static func remoteBackupManifest(_ entity: RemoteCatalogEntity) throws -> RemoteCatalogRecord {
        let payload = try JSONDecoder().decode(RemoteBackupManifestPayload.self, from: entity.payload)
        guard let manifestUUID = UUID(uuidString: payload.id),
              payload.manifestSHA256.count == 64,
              payload.manifestSHA256.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_REMOTE_BACKUP_MANIFEST", message: "Remote backup manifest is invalid")
        }
        return .backupManifest(
            manifest: BackupManifest(
                id: BackupManifestID(rawValue: manifestUUID), manifestSHA256: payload.manifestSHA256,
                recordedAt: payload.recordedAt.date,
                lastRestoreDrillAt: payload.lastRestoreDrillAt?.date,
                lastRestoreDrillResult: payload.lastRestoreDrillResult
            ),
            revision: entity.revision
        )
    }

    private static func assetIDs(in album: Album, catalog: CatalogDatabase) async throws -> [AssetID] {
        try await catalog.assets.orderedIDs(
            matching: AssetQuery(scope: .album(album.id)), sortedBy: .defaultSort
        )
    }

    private func ensureOutboxDrained() async throws {
        let status = try await catalog.cloud.status()
        if status.pendingOutboxCount > 0 { throw FramebaseSyncError.outboxNotDrained(status.pendingOutboxCount) }
    }

    private static func mutationPayload(
        idempotencyKey: String,
        type: String,
        targetID: String,
        payload: [String: JSONValue],
        baseRevision: Int64? = nil
    ) throws -> Data {
        try JSONEncoder().encode(MigrationMutationRequest(
            clientMutationID: idempotencyKey,
            operations: [MigrationMutationOperation(type: type, targetID: targetID, baseRevision: baseRevision, payload: payload)]
        ))
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

private struct MigrationMutationRequest: Encodable {
    let clientMutationID: String
    let operations: [MigrationMutationOperation]
    enum CodingKeys: String, CodingKey { case clientMutationID = "clientMutationId"; case operations }
}

private struct RemoteConflictContext: Codable {
    let code: String
    let message: String
    let requestID: String?
}

private struct MigrationMutationOperation: Encodable {
    let type: String
    let targetID: String
    let baseRevision: Int64?
    let payload: [String: JSONValue]
    enum CodingKeys: String, CodingKey { case type; case targetID = "targetId"; case baseRevision; case payload }
}

private struct QueuedMutationRequest: Decodable {
    let operations: [QueuedMutationContext]
}

private struct QueuedMutationContext: Decodable {
    let type: String
    let targetID: String

    enum CodingKeys: String, CodingKey {
        case type
        case targetID = "targetId"
    }
}

private struct RemoteAssetMetadata: Codable {
    let filename: String
    let storageKey: String
    let mediaType: String
    let width: Int?
    let height: Int?
    let fileSize: Int64
    let createdAt: Date
    let modifiedAt: Date
    let importedAt: Date
    let metadata: AssetMetadata

    init(asset: Asset) {
        filename = asset.filename
        storageKey = asset.storageKey.rawValue
        mediaType = asset.mediaType.rawValue
        width = asset.width
        height = asset.height
        fileSize = asset.fileSize
        createdAt = asset.createdAt
        modifiedAt = asset.modifiedAt
        importedAt = asset.importedAt
        metadata = asset.metadata
    }

    func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }
}

private struct RemoteFolderPayload: Decodable {
    let id: String
    let name: String
    let parentID: String?
    let sortOrder: Double?
    let createdAt: FlexibleDate?
    let updatedAt: FlexibleDate?
    enum CodingKeys: String, CodingKey { case id, name, parentID = "parentId", sortOrder, createdAt, updatedAt }
}

private struct RemoteBlobPayload: Decodable {
    let sha256: String
    let byteSize: Int64
    let mediaType: String
    let originalExtension: String
}

private struct RemoteDeletionPayload: Decodable {
    let deleted: Bool?
}

private struct RemoteExportReceiptPayload: Decodable {
    let id: String
    let manifestSHA256: String
    let assetIDs: [String]
    let completedAt: FlexibleDate

    enum CodingKeys: String, CodingKey {
        case id, manifestSHA256, assetIDs = "assetIds", completedAt
    }
}

private struct RemoteBackupManifestPayload: Decodable {
    let id: String
    let manifestSHA256: String
    let recordedAt: FlexibleDate
    let lastRestoreDrillAt: FlexibleDate?
    let lastRestoreDrillResult: String?
}

private struct RemoteAssetPayload: Decodable {
    let id: String
    let blobID: String
    let displayName: String
    let folderID: String
    let favorite: Bool
    let rating: Int
    let status: String?
    let trash: RemoteTrashPayload?
    let assetMetadata: RemoteAssetMetadata?
    let blob: RemoteBlobPayload
    enum CodingKeys: String, CodingKey {
        case id, blobID = "blobId", displayName, folderID = "folderId", favorite, rating, status, trash, assetMetadata, blob
    }
}

private struct RemoteTrashPayload: Decodable {
    let priorFolderID: String
    let priorAlbumIDs: [String]
    let priorTagIDs: [String]
    let trashedAt: FlexibleDate
    let scheduledPurgeAt: FlexibleDate
    enum CodingKeys: String, CodingKey {
        case priorFolderID = "priorFolderId"
        case priorAlbumIDs = "priorAlbumIds"
        case priorTagIDs = "priorTagIds"
        case trashedAt, scheduledPurgeAt
    }
}

private struct RemoteAlbumPayload: Decodable {
    let id: String
    let name: String
    let assetIDs: [String]
    let sortOrder: Double?
    let createdAt: FlexibleDate?
    let updatedAt: FlexibleDate?
    enum CodingKeys: String, CodingKey { case id, name, sortOrder, assetIDs = "assetIds", createdAt, updatedAt }
}

private struct RemoteTagPayload: Decodable {
    let id: String
    let name: String
    let assetIDs: [String]
    let createdAt: FlexibleDate?
    let updatedAt: FlexibleDate?
    enum CodingKeys: String, CodingKey { case id, name, assetIDs = "assetIds", createdAt, updatedAt }
}

private struct RemoteSavedSearchPayload: Decodable {
    let id: String
    let name: String
    let rules: AssetFilter
    let sort: AssetSort
    let createdAt: FlexibleDate?
    let updatedAt: FlexibleDate?
}

private struct FlexibleDate: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
            return
        }
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
            date = parsed
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported remote date")
    }
}

private enum JSONValue: Codable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
