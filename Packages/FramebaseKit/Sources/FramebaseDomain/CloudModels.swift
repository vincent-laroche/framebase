import Foundation

/// The local availability of an immutable original. Phase 3 only transitions
/// away from `.localVerified` after a separate, explicit retention decision.
public enum OriginalMaterializationState: String, Codable, Sendable {
    case localVerified
    case remoteVerified
    case remoteOnly
    case materializing
    case unavailable
}

public enum CloudBlobVerificationState: String, Codable, Sendable {
    case pendingHash
    case pendingUpload
    case uploading
    case verified
    case failed
    case abandoned
}

public struct CloudBlob: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let sha256: String
    public let byteSize: Int64
    public let mediaType: String
    public let originalExtension: String
    public var remoteBlobID: String?
    public var verificationState: CloudBlobVerificationState
    public var lastError: String?
    public var verifiedAt: Date?

    public init(
        sha256: String,
        byteSize: Int64,
        mediaType: String,
        originalExtension: String,
        remoteBlobID: String? = nil,
        verificationState: CloudBlobVerificationState = .pendingHash,
        lastError: String? = nil,
        verifiedAt: Date? = nil
    ) {
        self.id = sha256
        self.sha256 = sha256
        self.byteSize = byteSize
        self.mediaType = mediaType
        self.originalExtension = originalExtension
        self.remoteBlobID = remoteBlobID
        self.verificationState = verificationState
        self.lastError = lastError
        self.verifiedAt = verifiedAt
    }
}

public struct AssetCloudState: Hashable, Codable, Sendable {
    public let assetID: AssetID
    public let blobSHA256: String
    public var remoteRevision: Int64?
    public var materializationState: OriginalMaterializationState
    public var lastError: String?

    public init(
        assetID: AssetID,
        blobSHA256: String,
        remoteRevision: Int64? = nil,
        materializationState: OriginalMaterializationState = .localVerified,
        lastError: String? = nil
    ) {
        self.assetID = assetID
        self.blobSHA256 = blobSHA256
        self.remoteRevision = remoteRevision
        self.materializationState = materializationState
        self.lastError = lastError
    }
}

public enum SyncOutboxState: String, Codable, Sendable {
    case pending
    case inFlight
    case applied
    case conflict
    case failed
    case cancelled
}

public struct SyncOutboxEntry: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let idempotencyKey: String
    public let operation: String
    public let payload: Data
    public var state: SyncOutboxState
    public var attemptCount: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        idempotencyKey: String,
        operation: String,
        payload: Data,
        state: SyncOutboxState = .pending,
        attemptCount: Int = 0,
        nextAttemptAt: Date = .now,
        lastError: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.operation = operation
        self.payload = payload
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SyncConflictResolutionState: String, Codable, Sendable {
    case unresolved
    case keptLocal
    case keptRemote
    case merged
}

public struct SyncConflict: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let entityType: String
    public let entityID: String
    public let localPayload: Data
    public let remotePayload: Data
    public let detectedAt: Date
    public var resolution: SyncConflictResolutionState

    public init(
        id: UUID = UUID(),
        entityType: String,
        entityID: String,
        localPayload: Data,
        remotePayload: Data,
        detectedAt: Date = .now,
        resolution: SyncConflictResolutionState = .unresolved
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.localPayload = localPayload
        self.remotePayload = remotePayload
        self.detectedAt = detectedAt
        self.resolution = resolution
    }
}

public enum CloudLibraryMode: String, Codable, Sendable {
    case localOnly
    case preparingMigration
    case syncing
    case cloudBacked
    case paused
    case failed
}

public struct CloudLibraryStatus: Hashable, Codable, Sendable {
    public var mode: CloudLibraryMode
    public var deviceID: String?
    public var changeCursor: Int64
    public var lastSuccessfulSyncAt: Date?
    public var pendingOutboxCount: Int
    public var unresolvedConflictCount: Int
    public var lastError: String?

    public init(
        mode: CloudLibraryMode = .localOnly,
        deviceID: String? = nil,
        changeCursor: Int64 = 0,
        lastSuccessfulSyncAt: Date? = nil,
        pendingOutboxCount: Int = 0,
        unresolvedConflictCount: Int = 0,
        lastError: String? = nil
    ) {
        self.mode = mode
        self.deviceID = deviceID
        self.changeCursor = changeCursor
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.pendingOutboxCount = pendingOutboxCount
        self.unresolvedConflictCount = unresolvedConflictCount
        self.lastError = lastError
    }
}

public struct CloudMigrationManifestEntry: Hashable, Codable, Sendable, Identifiable {
    public let assetID: AssetID
    public let storageKey: AssetStorageKey
    public let byteSize: Int64
    public let sourceModifiedAt: Date
    public var sha256: String?
    public var capturedAt: Date

    public var id: AssetID { assetID }

    public init(
        assetID: AssetID,
        storageKey: AssetStorageKey,
        byteSize: Int64,
        sourceModifiedAt: Date,
        sha256: String? = nil,
        capturedAt: Date = .now
    ) {
        self.assetID = assetID
        self.storageKey = storageKey
        self.byteSize = byteSize
        self.sourceModifiedAt = sourceModifiedAt
        self.sha256 = sha256
        self.capturedAt = capturedAt
    }
}

/// A validated remote record ready to enter a local catalog. Sync converts
/// network JSON into this value before the catalog applies any SQL mutation.
public enum RemoteCatalogRecord: Sendable {
    case folder(folder: Folder, revision: Int64)
    case asset(asset: Asset, blob: CloudBlob, trashReceipt: AssetTrashReceipt?, revision: Int64)
    case album(album: Album, assetIDs: [AssetID], revision: Int64)
    case tag(tag: Tag, assetIDs: [AssetID], revision: Int64)
    case savedSearch(search: SavedSearch, revision: Int64)
    case exportReceipt(receipt: AssetExportReceipt, revision: Int64)
    case backupManifest(manifest: BackupManifest, revision: Int64)
}
