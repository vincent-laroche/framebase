import Foundation

public enum OriginalReceiveDisposition: String, Codable, Equatable, Sendable {
    case imported
    case alreadyPresent
}

/// Where the original bytes stand relative to the development R2 bucket.
public enum OriginalBlobDisposition: String, Codable, Equatable, Sendable {
    case localOnly
    case uploaded
    case alreadyInR2
}

public struct OriginalReceiveItem: Codable, Equatable, Sendable {
    public let filename: String
    public let assetID: String
    public let disposition: OriginalReceiveDisposition
    public let blob: OriginalBlobDisposition

    public init(filename: String, assetID: String, disposition: OriginalReceiveDisposition, blob: OriginalBlobDisposition) {
        self.filename = filename
        self.assetID = assetID
        self.disposition = disposition
        self.blob = blob
    }
}

public struct OriginalReceiveReport: Codable, Equatable, Sendable {
    public let librarySpace: String
    public let bucket: String
    public let items: [OriginalReceiveItem]
    public let failureFilenames: [String]

    public init(librarySpace: String, bucket: String, items: [OriginalReceiveItem], failureFilenames: [String]) {
        self.librarySpace = librarySpace
        self.bucket = bucket
        self.items = items
        self.failureFilenames = failureFilenames
    }
}

public enum OriginalReceiveError: Error, Equatable, LocalizedError, Sendable {
    case notALibraryPackage
    case librarySpaceMismatch(existing: LibrarySpace?, requested: LibrarySpace)
    case sourceInsideLibrary
    case unreadableImage(String)
    case stagingRecoveryFailed
    case cloudCredentialsIncomplete
    case productionTargetRefused
    case directUploadRequired

    public var errorDescription: String? {
        switch self {
        case .notALibraryPackage:
            "Pass a .framebase library package."
        case let .librarySpaceMismatch(existing, requested):
            if let existing {
                "This library is \(existing.displayName) and cannot receive \(requested.displayName) originals."
            } else {
                "This package is not the \(requested.displayName)."
            }
        case .sourceInsideLibrary:
            "Originals must be copied from outside the library package."
        case let .unreadableImage(name):
            "Framebase could not read \(name) as an image."
        case .stagingRecoveryFailed:
            "Staging recovery failed. No originals were imported."
        case .cloudCredentialsIncomplete:
            "Pass both --api and --token to store originals in framebase-blobs-dev, or neither to stay local."
        case .productionTargetRefused:
            "This command stores originals only in the development bucket framebase-blobs-dev."
        case .directUploadRequired:
            "Original bytes must upload directly to framebase-blobs-dev, not through the Worker."
        }
    }
}

public protocol OriginalReceiveCatalog: Sendable {
    var inboxFolderID: FolderID { get }
    func librarySpace() async throws -> LibrarySpace?
    func assignLibrarySpace(_ space: LibrarySpace) async throws
    func assetID(forContentSHA256 sha256: String) async throws -> AssetID?
    func asset(id: AssetID) async throws -> Asset?
    func insertOriginal(_ asset: Asset, contentSHA256: String) async throws
}
