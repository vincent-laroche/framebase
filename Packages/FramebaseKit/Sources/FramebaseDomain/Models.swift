import Foundation

public enum MediaType: String, Codable, Sendable {
    case stillImage
}

public enum FolderSystemKind: String, Codable, Sendable {
    case inbox
}

public struct Asset: Identifiable, Sendable {
    public let id: AssetID
    public var filename: String
    public var displayName: String
    public var parentFolderID: FolderID
    public let storageKey: AssetStorageKey
    public var localURL: URL?
    public let mediaType: MediaType
    public var width: Int?
    public var height: Int?
    public let fileSize: Int64
    public var createdAt: Date
    public var modifiedAt: Date
    public let importedAt: Date
    public var updatedAt: Date
    public var favorite: Bool
    public var rating: AssetRating
    public var metadata: AssetMetadata

    public init(
        id: AssetID,
        filename: String,
        displayName: String,
        parentFolderID: FolderID,
        storageKey: AssetStorageKey,
        localURL: URL? = nil,
        mediaType: MediaType = .stillImage,
        width: Int? = nil,
        height: Int? = nil,
        fileSize: Int64,
        createdAt: Date,
        modifiedAt: Date,
        importedAt: Date,
        updatedAt: Date,
        favorite: Bool = false,
        rating: AssetRating = .unrated,
        metadata: AssetMetadata = .init()
    ) {
        self.id = id
        self.filename = filename
        self.displayName = displayName
        self.parentFolderID = parentFolderID
        self.storageKey = storageKey
        self.localURL = localURL
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.importedAt = importedAt
        self.updatedAt = updatedAt
        self.favorite = favorite
        self.rating = rating
        self.metadata = metadata
    }
}

public struct Folder: Identifiable, Codable, Hashable, Sendable {
    public let id: FolderID
    public var name: FolderName
    public var parentFolderID: FolderID?
    public let createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Int64
    public var systemKind: FolderSystemKind?

    public init(
        id: FolderID,
        name: FolderName,
        parentFolderID: FolderID? = nil,
        createdAt: Date,
        updatedAt: Date,
        sortOrder: Int64,
        systemKind: FolderSystemKind? = nil
    ) {
        self.id = id
        self.name = name
        self.parentFolderID = parentFolderID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.systemKind = systemKind
    }
}

public struct Album: Identifiable, Codable, Hashable, Sendable {
    public let id: AlbumID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Int64

    public init(
        id: AlbumID,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        sortOrder: Int64
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }
}

public struct AlbumAsset: Codable, Hashable, Sendable {
    public let albumID: AlbumID
    public let assetID: AssetID
    public let addedAt: Date
    public var sortOrder: Int64

    public init(albumID: AlbumID, assetID: AssetID, addedAt: Date, sortOrder: Int64) {
        self.albumID = albumID
        self.assetID = assetID
        self.addedAt = addedAt
        self.sortOrder = sortOrder
    }
}

public struct Tag: Identifiable, Codable, Hashable, Sendable {
    public let id: TagID
    public var name: TagName
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: TagID = TagID(), name: TagName, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AssetTag: Codable, Hashable, Sendable {
    public let assetID: AssetID
    public let tagID: TagID
    public let addedAt: Date

    public init(assetID: AssetID, tagID: TagID, addedAt: Date = .now) {
        self.assetID = assetID
        self.tagID = tagID
        self.addedAt = addedAt
    }
}

public struct SavedSearch: Identifiable, Codable, Hashable, Sendable {
    public let id: SavedSearchID
    public var name: SavedSearchName
    public var filter: AssetFilter
    public var sort: AssetSort
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: SavedSearchID = SavedSearchID(),
        name: SavedSearchName,
        filter: AssetFilter,
        sort: AssetSort = .defaultSort,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.filter = filter
        self.sort = sort
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AssetTrashReceipt: Codable, Hashable, Sendable {
    public let assetID: AssetID
    public let priorFolderID: FolderID
    public let albumIDs: [AlbumID]
    public let tagIDs: [TagID]
    public let trashedAt: Date
    public let scheduledPurgeAt: Date

    public init(
        assetID: AssetID,
        priorFolderID: FolderID,
        albumIDs: [AlbumID],
        tagIDs: [TagID],
        trashedAt: Date,
        scheduledPurgeAt: Date
    ) {
        self.assetID = assetID
        self.priorFolderID = priorFolderID
        self.albumIDs = albumIDs
        self.tagIDs = tagIDs
        self.trashedAt = trashedAt
        self.scheduledPurgeAt = scheduledPurgeAt
    }
}

public struct LibraryTemplateApplicationReceipt: Sendable {
    public let createdFolderIDs: [FolderID]
    public let createdTagIDs: [TagID]

    public init(createdFolderIDs: [FolderID], createdTagIDs: [TagID]) {
        self.createdFolderIDs = createdFolderIDs
        self.createdTagIDs = createdTagIDs
    }
}

/// A non-mutating review of the starter-template changes that would be made
/// to the currently opened catalog.
public struct LibraryTemplateApplicationPreview: Identifiable, Sendable {
    public let id: UUID
    public let folderPathsToCreate: [String]
    public let tagNamesToCreate: [TagName]
    public let onFirstUseFolderPaths: [String]

    public init(
        id: UUID = UUID(),
        folderPathsToCreate: [String],
        tagNamesToCreate: [TagName],
        onFirstUseFolderPaths: [String]
    ) {
        self.id = id
        self.folderPathsToCreate = folderPathsToCreate
        self.tagNamesToCreate = tagNamesToCreate
        self.onFirstUseFolderPaths = onFirstUseFolderPaths
    }
}

public struct AssetExportManifestEntry: Codable, Hashable, Sendable {
    public let assetID: AssetID
    public let filename: String
    public let byteSize: Int64
    public let sha256: String

    public init(assetID: AssetID, filename: String, byteSize: Int64, sha256: String) {
        self.assetID = assetID
        self.filename = filename
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

public struct AssetExportManifest: Codable, Hashable, Sendable {
    public let formatVersion: Int
    public let createdAt: Date
    public let assets: [AssetExportManifestEntry]

    public init(formatVersion: Int = 1, createdAt: Date = .now, assets: [AssetExportManifestEntry]) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.assets = assets
    }
}

public struct AssetExportReceipt: Identifiable, Codable, Hashable, Sendable {
    public let id: ExportReceiptID
    public let manifestSHA256: String
    public let assetIDs: [AssetID]
    public let completedAt: Date

    public init(
        id: ExportReceiptID = ExportReceiptID(),
        manifestSHA256: String,
        assetIDs: [AssetID],
        completedAt: Date = .now
    ) {
        self.id = id
        self.manifestSHA256 = manifestSHA256
        self.assetIDs = assetIDs
        self.completedAt = completedAt
    }
}

/// Records only an integrity manifest and restore-drill result. It never stores
/// original bytes or a destination path inside the catalog.
public struct BackupManifest: Identifiable, Codable, Hashable, Sendable {
    public let id: BackupManifestID
    public let manifestSHA256: String
    public let recordedAt: Date
    public var lastRestoreDrillAt: Date?
    public var lastRestoreDrillResult: String?

    public init(
        id: BackupManifestID = BackupManifestID(),
        manifestSHA256: String,
        recordedAt: Date = .now,
        lastRestoreDrillAt: Date? = nil,
        lastRestoreDrillResult: String? = nil
    ) {
        self.id = id
        self.manifestSHA256 = manifestSHA256
        self.recordedAt = recordedAt
        self.lastRestoreDrillAt = lastRestoreDrillAt
        self.lastRestoreDrillResult = lastRestoreDrillResult
    }
}

/// A read-only exact-byte duplicate group. Membership is admitted only after
/// the immutable blob hash has been independently verified.
public struct DuplicateCandidate: Identifiable, Hashable, Sendable {
    public let sha256: String
    public let assetIDs: [AssetID]

    public var id: String { sha256 }

    public init(sha256: String, assetIDs: [AssetID]) {
        self.sha256 = sha256
        self.assetIDs = assetIDs
    }
}
