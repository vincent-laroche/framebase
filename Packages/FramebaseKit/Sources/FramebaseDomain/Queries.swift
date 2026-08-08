import Foundation

public enum AssetScope: Hashable, Sendable {
    case allAssets
    case inbox
    case favorites
    case folder(FolderID)
    case album(AlbumID)
}

public struct AssetQuery: Hashable, Sendable {
    public var scope: AssetScope

    public init(scope: AssetScope) {
        self.scope = scope
    }
}

public struct AssetSort: Hashable, Sendable {
    public enum Key: String, Codable, CaseIterable, Sendable {
        case displayName
        case importedAt
        case modifiedAt
        case createdAt
        case fileSize
        case rating
    }

    public enum Direction: String, Codable, Sendable {
        case ascending
        case descending
    }

    public var key: Key
    public var direction: Direction

    public init(key: Key, direction: Direction) {
        self.key = key
        self.direction = direction
    }

    public static let defaultSort = AssetSort(key: .importedAt, direction: .descending)
}

public struct AssetGridRecord: Identifiable, Sendable {
    public let id: AssetID
    public let displayName: String
    public let storageKey: AssetStorageKey
    public let fileSize: Int64
    public let modifiedAt: Date
    public let width: Int?
    public let height: Int?
    public let favorite: Bool
    public let rating: AssetRating
    public let originalAvailable: Bool

    public init(
        id: AssetID,
        displayName: String,
        storageKey: AssetStorageKey,
        fileSize: Int64,
        modifiedAt: Date,
        width: Int?,
        height: Int?,
        favorite: Bool,
        rating: AssetRating,
        originalAvailable: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.storageKey = storageKey
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.width = width
        self.height = height
        self.favorite = favorite
        self.rating = rating
        self.originalAvailable = originalAvailable
    }
}

public struct AssetPage: Sendable {
    public let records: [AssetGridRecord]
    public let offset: Int
    public let totalCount: Int

    public init(records: [AssetGridRecord], offset: Int, totalCount: Int) {
        self.records = records
        self.offset = offset
        self.totalCount = totalCount
    }

    public var hasMore: Bool {
        offset + records.count < totalCount
    }
}

public struct FolderTreeSnapshot: Sendable {
    public let folders: [Folder]
    public let roots: [FolderID]
    public let childrenByParent: [FolderID: [FolderID]]
    public let inboxID: FolderID

    public init(
        folders: [Folder],
        roots: [FolderID],
        childrenByParent: [FolderID: [FolderID]],
        inboxID: FolderID
    ) {
        self.folders = folders
        self.roots = roots
        self.childrenByParent = childrenByParent
        self.inboxID = inboxID
    }
}

public struct CatalogChange: Sendable {
    public enum Area: String, Codable, Sendable {
        case assets
        case folders
        case albums
        case settings
    }

    public let areas: Set<Area>
    public let affectedAssetIDs: Set<AssetID>
    public let affectedFolderIDs: Set<FolderID>

    public init(
        areas: Set<Area>,
        affectedAssetIDs: Set<AssetID> = [],
        affectedFolderIDs: Set<FolderID> = []
    ) {
        self.areas = areas
        self.affectedAssetIDs = affectedAssetIDs
        self.affectedFolderIDs = affectedFolderIDs
    }
}
