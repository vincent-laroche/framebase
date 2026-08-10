import Foundation

public enum AssetScope: Hashable, Sendable {
    case allAssets
    case inbox
    case favorites
    case trash
    case folder(FolderID)
    case album(AlbumID)
}

public struct AssetFilter: Codable, Hashable, Sendable {
    public var text: String?
    /// Local-only recognized text. This remains distinct from the regular
    /// metadata search so a user can explicitly control when Vision-derived
    /// text participates in a catalog query.
    public var recognizedText: String?
    public var folderPath: String?
    public var tagIDs: Set<TagID>
    public var albumIDs: Set<AlbumID>
    public var dateRange: ClosedRange<Date>?
    public var rating: AssetRating?
    public var favorite: Bool?

    public init(
        text: String? = nil,
        recognizedText: String? = nil,
        folderPath: String? = nil,
        tagIDs: Set<TagID> = [],
        albumIDs: Set<AlbumID> = [],
        dateRange: ClosedRange<Date>? = nil,
        rating: AssetRating? = nil,
        favorite: Bool? = nil
    ) {
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.recognizedText = recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.folderPath = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.tagIDs = tagIDs
        self.albumIDs = albumIDs
        self.dateRange = dateRange
        self.rating = rating
        self.favorite = favorite
    }
}

public struct AssetQuery: Hashable, Sendable {
    public var scope: AssetScope
    public var filter: AssetFilter

    public init(scope: AssetScope, filter: AssetFilter = .init()) {
        self.scope = scope
        self.filter = filter
    }
}

public struct AssetSort: Codable, Hashable, Sendable {
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
        case tags
        case savedSearches
        case trash
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
