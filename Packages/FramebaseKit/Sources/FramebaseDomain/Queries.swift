import Foundation

public enum AssetScope: Codable, Hashable, Sendable {
    case allAssets
    case inbox
    case favorites
    case folder(FolderID)
    case album(AlbumID)
    case tag(TagID)
    case trash
}

public struct AssetDateRange: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
}

/// Structured, local-only criteria applied in addition to an `AssetScope`.
/// Tag and album sets use AND semantics: every supplied relationship must be
/// present on a matching asset.
public struct AssetSearchCriteria: Codable, Hashable, Sendable {
    public var text: String?
    public var folderPathText: String?
    public var metadataText: String?
    public var capturedDateRange: AssetDateRange?
    public var rating: AssetRating?
    public var favorite: Bool?
    public var tagIDs: Set<TagID>
    public var albumIDs: Set<AlbumID>

    public init(
        text: String? = nil,
        folderPathText: String? = nil,
        metadataText: String? = nil,
        capturedDateRange: AssetDateRange? = nil,
        rating: AssetRating? = nil,
        favorite: Bool? = nil,
        tagIDs: Set<TagID> = [],
        albumIDs: Set<AlbumID> = []
    ) {
        self.text = Self.normalized(text)
        self.folderPathText = Self.normalized(folderPathText)
        self.metadataText = Self.normalized(metadataText)
        self.capturedDateRange = capturedDateRange
        self.rating = rating
        self.favorite = favorite
        self.tagIDs = tagIDs
        self.albumIDs = albumIDs
    }

    public var isEmpty: Bool {
        text == nil
            && folderPathText == nil
            && metadataText == nil
            && capturedDateRange == nil
            && rating == nil
            && favorite == nil
            && tagIDs.isEmpty
            && albumIDs.isEmpty
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct AssetQuery: Codable, Hashable, Sendable {
    public var scope: AssetScope
    public var criteria: AssetSearchCriteria

    public init(scope: AssetScope) {
        self.init(scope: scope, criteria: .init())
    }

    public init(scope: AssetScope, criteria: AssetSearchCriteria) {
        self.scope = scope
        self.criteria = criteria
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
        case tags
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
