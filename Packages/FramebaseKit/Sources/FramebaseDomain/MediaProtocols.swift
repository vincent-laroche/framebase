import Foundation

public struct StagedBlob: Sendable {
    public let assetID: AssetID
    public let sourceURL: URL
    public let stagingURL: URL
    public let preferredFilenameExtension: String

    public init(
        assetID: AssetID,
        sourceURL: URL,
        stagingURL: URL,
        preferredFilenameExtension: String
    ) {
        self.assetID = assetID
        self.sourceURL = sourceURL
        self.stagingURL = stagingURL
        self.preferredFilenameExtension = preferredFilenameExtension
    }
}

public struct CommittedBlob: Sendable {
    public let assetID: AssetID
    public let storageKey: AssetStorageKey
    public let localURL: URL
    public let fileSize: Int64
    public let modifiedAt: Date

    public init(
        assetID: AssetID,
        storageKey: AssetStorageKey,
        localURL: URL,
        fileSize: Int64,
        modifiedAt: Date
    ) {
        self.assetID = assetID
        self.storageKey = storageKey
        self.localURL = localURL
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

public protocol AssetBlobStore: Sendable {
    func stage(sourceURL: URL, for assetID: AssetID) async throws -> StagedBlob
    func commit(_ stagedBlob: StagedBlob) async throws -> CommittedBlob
    func resolve(_ storageKey: AssetStorageKey) async throws -> URL
    func validate(_ storageKey: AssetStorageKey) async -> Bool
    func removeNewlyCommitted(_ committedBlob: CommittedBlob) async throws
    func recoverStaging() async throws -> StagingRecoveryResult
}

/// Optional capability of the managed local store. Remote originals can only
/// re-enter the package through this checked staging boundary; UI code never
/// writes a downloaded file into `Originals/` directly.
public protocol RemoteOriginalMaterializing: AssetBlobStore {
    func materializeRemoteOriginal(
        from temporaryURL: URL,
        assetID: AssetID,
        storageKey: AssetStorageKey
    ) async throws -> URL
}

public struct StagingRecoveryResult: Sendable {
    public let recoveredCount: Int
    public let failedURLs: [URL]

    public init(recoveredCount: Int, failedURLs: [URL] = []) {
        self.recoveredCount = recoveredCount
        self.failedURLs = failedURLs
    }
}

public struct ExtractedAssetMetadata: Sendable {
    public let width: Int?
    public let height: Int?
    public let createdAt: Date?
    public let metadata: AssetMetadata

    public init(width: Int?, height: Int?, createdAt: Date?, metadata: AssetMetadata) {
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public protocol MetadataExtractor: Sendable {
    func supportsImage(at url: URL) async -> Bool
    func extract(from url: URL) async throws -> ExtractedAssetMetadata
}

public struct AssetFingerprint: Hashable, Codable, Sendable {
    public let assetID: AssetID
    public let fileSize: Int64
    public let modifiedAtMilliseconds: Int64

    public init(assetID: AssetID, fileSize: Int64, modifiedAtMilliseconds: Int64) {
        self.assetID = assetID
        self.fileSize = fileSize
        self.modifiedAtMilliseconds = modifiedAtMilliseconds
    }
}

public struct ThumbnailTarget: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int
    public let displayScale: Double

    public init(width: Int, height: Int, displayScale: Double) {
        self.width = width
        self.height = height
        self.displayScale = displayScale
    }
}

public struct ThumbnailRequest: Hashable, Sendable {
    public let id: ThumbnailRequestID
    public let storageKey: AssetStorageKey
    public let fingerprint: AssetFingerprint
    public let target: ThumbnailTarget

    public init(
        id: ThumbnailRequestID = ThumbnailRequestID(),
        storageKey: AssetStorageKey,
        fingerprint: AssetFingerprint,
        target: ThumbnailTarget
    ) {
        self.id = id
        self.storageKey = storageKey
        self.fingerprint = fingerprint
        self.target = target
    }
}

public struct ThumbnailPayload: Sendable {
    public let encodedData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(encodedData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.encodedData = encodedData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public protocol ThumbnailProvider: Sendable {
    func thumbnail(for request: ThumbnailRequest) async throws -> ThumbnailPayload
    func preview(for request: ThumbnailRequest) async throws -> ThumbnailPayload
    func cancel(requestID: ThumbnailRequestID) async
    func clearDerivedCache() async throws
}

public struct ImportRequest: Sendable {
    public let sourceURLs: [URL]
    public let destinationFolderID: FolderID

    public init(sourceURLs: [URL], destinationFolderID: FolderID) {
        self.sourceURLs = sourceURLs
        self.destinationFolderID = destinationFolderID
    }
}

public struct ImportProgress: Sendable {
    public let completedCount: Int
    public let totalCount: Int
    public let currentFilename: String?

    public init(completedCount: Int, totalCount: Int, currentFilename: String?) {
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.currentFilename = currentFilename
    }
}

public struct ImportFailure: Sendable {
    public let sourceURL: URL
    public let reason: String

    public init(sourceURL: URL, reason: String) {
        self.sourceURL = sourceURL
        self.reason = reason
    }
}

public struct ImportResult: Sendable {
    public let importedAssetIDs: [AssetID]
    public let failures: [ImportFailure]
    public let cancelled: Bool

    public init(importedAssetIDs: [AssetID], failures: [ImportFailure], cancelled: Bool) {
        self.importedAssetIDs = importedAssetIDs
        self.failures = failures
        self.cancelled = cancelled
    }
}

public protocol ImportCoordinator: Sendable {
    func importAssets(
        _ request: ImportRequest,
        progress: @escaping @Sendable (ImportProgress) async -> Void
    ) async throws -> ImportResult
    func cancelCurrentImport() async
}
