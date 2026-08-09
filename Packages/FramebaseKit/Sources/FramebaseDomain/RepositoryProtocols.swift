import Foundation

public protocol AssetRepository: Sendable {
    func count(matching query: AssetQuery) async throws -> Int
    func orderedIDs(matching query: AssetQuery, sortedBy sort: AssetSort) async throws -> [AssetID]
    func page(
        matching query: AssetQuery,
        sortedBy sort: AssetSort,
        offset: Int,
        limit: Int
    ) async throws -> AssetPage
    func asset(id: AssetID) async throws -> Asset?
    func assets(ids: Set<AssetID>) async throws -> [Asset]
    func observe(matching query: AssetQuery) -> AsyncThrowingStream<CatalogChange, any Error>
    func updateDisplayName(_ displayName: String, for assetID: AssetID) async throws
    func updateRating(_ rating: AssetRating, for assetIDs: Set<AssetID>) async throws
    func updateFavorite(_ favorite: Bool, for assetIDs: Set<AssetID>) async throws
    func moveAssets(_ assetIDs: Set<AssetID>, to folderID: FolderID) async throws
    /// Moves a complete selection atomically and returns its prior logical
    /// locations for undo. Managed original files are never part of this
    /// receipt.
    func moveAssetsWithReceipt(_ assetIDs: Set<AssetID>, to folderID: FolderID) async throws -> AssetMoveReceipt
    /// Replays a prior logical-location receipt atomically and returns the
    /// current locations, allowing redo without filesystem mutation.
    func restoreAssetLocations(using receipt: AssetMoveReceipt) async throws -> AssetMoveReceipt
    func moveToTrash(_ assetIDs: Set<AssetID>, retentionDays: Int) async throws -> TrashReceipt
    /// Returns the persisted local-trash metadata for the supplied assets.
    /// Assets outside Trash are omitted; this read path cannot purge anything.
    func trashEntries(assetIDs: Set<AssetID>) async throws -> [TrashEntry]
    func restoreFromTrash(_ assetIDs: Set<AssetID>) async throws -> TrashReceipt
    func restoreFromTrash(using receipt: TrashReceipt) async throws
}

public protocol FolderRepository: Sendable {
    func treeSnapshot() async throws -> FolderTreeSnapshot
    func observeTree() -> AsyncThrowingStream<FolderTreeSnapshot, any Error>
    func createFolder(named name: FolderName, in parentFolderID: FolderID?) async throws -> Folder
    /// Creates a folder with a caller-specified identity rather than a
    /// generated one. Exists for applying a pulled cloud change event, which
    /// must recreate the folder under the same ID the origin device used.
    func createFolder(id: FolderID, named name: FolderName, in parentFolderID: FolderID?) async throws -> Folder
    func renameFolder(_ folderID: FolderID, to name: FolderName) async throws
    func reparentFolder(_ folderID: FolderID, to parentFolderID: FolderID?) async throws
    func deletePreservingAssets(_ folderID: FolderID) async throws -> FolderDeletionReceipt
    func restoreDeletedFolder(using receipt: FolderDeletionReceipt) async throws
}

public protocol AlbumRepository: Sendable {
    func albums() async throws -> [Album]
    func observeAlbums() -> AsyncThrowingStream<[Album], any Error>
    func createAlbum(named name: String) async throws -> Album
    func renameAlbum(_ albumID: AlbumID, to name: String) async throws
    /// Replaces the complete logical order atomically. The supplied IDs must
    /// be an exact permutation of the current album set.
    func reorderAlbums(_ albumIDs: [AlbumID]) async throws
    func deleteAlbum(_ albumID: AlbumID) async throws -> AlbumDeletionReceipt
    func restoreDeletedAlbum(using receipt: AlbumDeletionReceipt) async throws
    func addAssets(_ assetIDs: Set<AssetID>, to albumID: AlbumID) async throws
    func removeAssets(_ assetIDs: Set<AssetID>, from albumID: AlbumID) async throws
}

public protocol BlobRepository: Sendable {
    func register(_ blob: Blob) async throws
    func blob(sha256: String) async throws -> Blob?
    func link(assetID: AssetID, toBlobSHA256 sha256: String) async throws
    func blobSHA256(for assetID: AssetID) async throws -> String?
    func duplicateCandidates() async throws -> [DuplicateCandidate]
}

public protocol TagRepository: Sendable {
    func tags() async throws -> [Tag]
    func observeTags() -> AsyncThrowingStream<[Tag], any Error>
    func createTag(named name: String) async throws -> Tag
    func renameTag(_ tagID: TagID, to name: String) async throws
    func deleteTag(_ tagID: TagID) async throws -> TagDeletionReceipt
    func restoreDeletedTag(using receipt: TagDeletionReceipt) async throws
    func addTags(_ tagIDs: Set<TagID>, to assetIDs: Set<AssetID>) async throws
    func removeTags(_ tagIDs: Set<TagID>, from assetIDs: Set<AssetID>) async throws
}

public protocol SavedSearchRepository: Sendable {
    func savedSearches() async throws -> [SavedSearch]
    func observeSavedSearches() -> AsyncThrowingStream<[SavedSearch], any Error>
    func createSavedSearch(named name: String, query: AssetQuery) async throws -> SavedSearch
    func renameSavedSearch(_ savedSearchID: SavedSearchID, to name: String) async throws
    func deleteSavedSearch(_ savedSearchID: SavedSearchID) async throws
}

public protocol SmartCollectionRepository: Sendable {
    func smartCollections() async throws -> [SmartCollection]
    func observeSmartCollections() -> AsyncThrowingStream<[SmartCollection], any Error>
    func createSmartCollection(named name: String, query: AssetQuery) async throws -> SmartCollection
    func renameSmartCollection(_ smartCollectionID: SmartCollectionID, to name: String) async throws
    func deleteSmartCollection(_ smartCollectionID: SmartCollectionID) async throws
}

public struct FolderDeletionReceipt: Sendable {
    public let deletedFolders: [Folder]
    public let priorAssetAssignments: [AssetID: FolderID]

    public init(deletedFolders: [Folder], priorAssetAssignments: [AssetID: FolderID]) {
        self.deletedFolders = deletedFolders
        self.priorAssetAssignments = priorAssetAssignments
    }
}

public struct AlbumDeletionReceipt: Sendable {
    public let album: Album
    public let memberships: [AlbumAsset]

    public init(album: Album, memberships: [AlbumAsset]) {
        self.album = album
        self.memberships = memberships
    }
}

public struct TagDeletionReceipt: Sendable {
    public let tag: Tag
    public let memberships: [TagAsset]

    public init(tag: Tag, memberships: [TagAsset]) {
        self.tag = tag
        self.memberships = memberships
    }
}

public struct TrashEntry: Codable, Hashable, Sendable {
    public let assetID: AssetID
    public let priorFolderID: FolderID
    public let trashedAt: Date
    public let expiresAt: Date

    public init(assetID: AssetID, priorFolderID: FolderID, trashedAt: Date, expiresAt: Date) {
        self.assetID = assetID
        self.priorFolderID = priorFolderID
        self.trashedAt = trashedAt
        self.expiresAt = expiresAt
    }
}

public struct AssetMoveReceipt: Sendable {
    public let priorFolderByAssetID: [AssetID: FolderID]

    public init(priorFolderByAssetID: [AssetID: FolderID]) {
        self.priorFolderByAssetID = priorFolderByAssetID
    }
}

public struct TrashReceipt: Sendable {
    public let entries: [TrashEntry]

    public init(entries: [TrashEntry]) {
        self.entries = entries
    }
}
