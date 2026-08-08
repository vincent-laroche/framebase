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
}

public struct FolderDeletionReceipt: Sendable {
    public let deletedFolders: [Folder]
    public let priorAssetAssignments: [AssetID: FolderID]

    public init(deletedFolders: [Folder], priorAssetAssignments: [AssetID: FolderID]) {
        self.deletedFolders = deletedFolders
        self.priorAssetAssignments = priorAssetAssignments
    }
}
