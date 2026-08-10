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
    func trashAssets(_ assetIDs: Set<AssetID>, retentionDays: Int) async throws -> [AssetTrashReceipt]
    func restoreAssets(_ assetIDs: Set<AssetID>) async throws
    func trashedAssets(sortedBy sort: AssetSort) async throws -> AssetPage
    func trashReceipts(for assetIDs: Set<AssetID>) async throws -> [AssetTrashReceipt]
}

public protocol FolderRepository: Sendable {
    func treeSnapshot() async throws -> FolderTreeSnapshot
    func observeTree() -> AsyncThrowingStream<FolderTreeSnapshot, any Error>
    func createFolder(named name: FolderName, in parentFolderID: FolderID?) async throws -> Folder
    func renameFolder(_ folderID: FolderID, to name: FolderName) async throws
    func reparentFolder(_ folderID: FolderID, to parentFolderID: FolderID?) async throws
    func deletePreservingAssets(_ folderID: FolderID) async throws -> FolderDeletionReceipt
    func restoreDeletedFolder(using receipt: FolderDeletionReceipt) async throws
}

public protocol AlbumRepository: Sendable {
    func albums() async throws -> [Album]
    func observeAlbums() -> AsyncThrowingStream<[Album], any Error>
    func addAssets(_ assetIDs: Set<AssetID>, to albumID: AlbumID) async throws
    func removeAssets(_ assetIDs: Set<AssetID>, from albumID: AlbumID) async throws
    func createAlbum(named name: String) async throws -> Album
    func renameAlbum(_ albumID: AlbumID, to name: String) async throws
    func reorderAlbum(_ albumID: AlbumID, after predecessorID: AlbumID?) async throws
    func deleteAlbum(_ albumID: AlbumID) async throws
}

public protocol TagRepository: Sendable {
    func tags() async throws -> [Tag]
    func observeTags() -> AsyncThrowingStream<[Tag], any Error>
    func createTag(named name: TagName) async throws -> Tag
    func renameTag(_ tagID: TagID, to name: TagName) async throws
    func deleteTag(_ tagID: TagID) async throws
    func tags(for assetIDs: Set<AssetID>) async throws -> [AssetID: [Tag]]
    func addTags(_ tagIDs: Set<TagID>, to assetIDs: Set<AssetID>) async throws
    func removeTags(_ tagIDs: Set<TagID>, from assetIDs: Set<AssetID>) async throws
}

public protocol SavedSearchRepository: Sendable {
    func savedSearches() async throws -> [SavedSearch]
    func save(_ savedSearch: SavedSearch) async throws
    func deleteSavedSearch(_ savedSearchID: SavedSearchID) async throws
}

public protocol ExportReceiptRepository: Sendable {
    func record(_ receipt: AssetExportReceipt) async throws
    func receipts() async throws -> [AssetExportReceipt]
}

public protocol BackupManifestRepository: Sendable {
    func record(_ manifest: BackupManifest) async throws
    func manifests() async throws -> [BackupManifest]
    func recordRestoreDrill(manifestID: BackupManifestID, result: String, at date: Date) async throws
}

public protocol IntelligenceRepository: Sendable {
    func store(_ result: AssetAnalysisResult) async throws
    func results(for assetID: AssetID) async throws -> [AssetAnalysisResult]
    func markStaleIfSourceDigestDiffers(assetID: AssetID, digest: String) async throws
    func assetIDsMatchingOCR(_ text: String) async throws -> [AssetID]
}

public struct FolderDeletionReceipt: Sendable {
    public let deletedFolders: [Folder]
    public let priorAssetAssignments: [AssetID: FolderID]

    public init(deletedFolders: [Folder], priorAssetAssignments: [AssetID: FolderID]) {
        self.deletedFolders = deletedFolders
        self.priorAssetAssignments = priorAssetAssignments
    }
}
