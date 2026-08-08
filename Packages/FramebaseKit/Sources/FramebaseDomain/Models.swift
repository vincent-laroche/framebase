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
