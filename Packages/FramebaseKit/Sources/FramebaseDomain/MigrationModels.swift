import Foundation

public enum BlobUploadState: String, Codable, Equatable, Sendable {
    case pending
    case uploaded
    case verified
    case failed
}

/// Immutable content-addressed evidence for one original binary. The local
/// `Asset.storageKey` remains a separate managed-file locator.
public struct Blob: Equatable, Sendable {
    public let sha256: String
    public let byteSize: Int64
    public let mediaType: String
    public let originalExtension: String
    public let r2Key: String
    public let uploadState: BlobUploadState
    public let verificationETag: String?
    public let verifiedAt: Date?
    public let createdAt: Date

    public init(sha256: String, byteSize: Int64, mediaType: String, originalExtension: String, r2Key: String, uploadState: BlobUploadState, verificationETag: String?, verifiedAt: Date?, createdAt: Date) {
        self.sha256 = sha256
        self.byteSize = byteSize
        self.mediaType = mediaType
        self.originalExtension = originalExtension
        self.r2Key = r2Key
        self.uploadState = uploadState
        self.verificationETag = verificationETag
        self.verifiedAt = verifiedAt
        self.createdAt = createdAt
    }
}

/// A read-only duplicate suggestion. Equal SHA-256 is the only criterion;
/// Framebase never merges or deletes either original automatically.
public struct DuplicateCandidate: Equatable, Sendable {
    public let sha256: String
    public let assetIDs: [AssetID]

    public init(sha256: String, assetIDs: [AssetID]) {
        self.sha256 = sha256
        self.assetIDs = assetIDs
    }
}
