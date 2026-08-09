import FramebaseDomain

/// Wraps a real `AssetRepository`, recording the mutations the cloud
/// contract supports (`move_assets`, `update_rating`, `update_favorite`) to
/// the outbox after each successful local write. Asset creation is never
/// recorded — it always requires managed-original bytes, which is out of
/// scope for metadata-only sync. Every other method passes through
/// unchanged.
public struct SyncingAssetRepository: AssetRepository {
    private let wrapped: any AssetRepository
    private let recorder: CatalogOutboxRecorder

    public init(wrapping wrapped: any AssetRepository, recorder: CatalogOutboxRecorder) {
        self.wrapped = wrapped
        self.recorder = recorder
    }

    public func count(matching query: AssetQuery) async throws -> Int {
        try await wrapped.count(matching: query)
    }

    public func orderedIDs(matching query: AssetQuery, sortedBy sort: AssetSort) async throws -> [AssetID] {
        try await wrapped.orderedIDs(matching: query, sortedBy: sort)
    }

    public func page(
        matching query: AssetQuery,
        sortedBy sort: AssetSort,
        offset: Int,
        limit: Int
    ) async throws -> AssetPage {
        try await wrapped.page(matching: query, sortedBy: sort, offset: offset, limit: limit)
    }

    public func asset(id: AssetID) async throws -> Asset? {
        try await wrapped.asset(id: id)
    }

    public func assets(ids: Set<AssetID>) async throws -> [Asset] {
        try await wrapped.assets(ids: ids)
    }

    public func observe(matching query: AssetQuery) -> AsyncThrowingStream<CatalogChange, any Error> {
        wrapped.observe(matching: query)
    }

    public func updateDisplayName(_ displayName: String, for assetID: AssetID) async throws {
        try await wrapped.updateDisplayName(displayName, for: assetID)
    }

    public func updateRating(_ rating: AssetRating, for assetIDs: Set<AssetID>) async throws {
        try await wrapped.updateRating(rating, for: assetIDs)
        try await recorder.recordRatingChanged(rating, for: assetIDs)
    }

    public func updateFavorite(_ favorite: Bool, for assetIDs: Set<AssetID>) async throws {
        try await wrapped.updateFavorite(favorite, for: assetIDs)
        try await recorder.recordFavoriteChanged(favorite, for: assetIDs)
    }

    public func moveAssets(_ assetIDs: Set<AssetID>, to folderID: FolderID) async throws {
        try await wrapped.moveAssets(assetIDs, to: folderID)
        try await recorder.recordAssetsMoved(assetIDs, to: folderID)
    }
}
