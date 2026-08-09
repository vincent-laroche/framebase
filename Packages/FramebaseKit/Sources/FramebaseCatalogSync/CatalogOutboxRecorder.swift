import FramebaseAPIClient
import FramebaseDomain
import FramebaseSync
import Foundation

/// Turns a successful local catalog mutation into an `OutboxMutation` and
/// enqueues it. One `MutationOperation` per affected entity, matching
/// `Cloud/apps/api`'s one-`change_events`-row-per-operation model — a
/// multi-asset rating change becomes N operations inside one outbox row
/// (and one `Idempotency-Key`), not N separate rows.
public struct CatalogOutboxRecorder: Sendable {
    private let outbox: any OutboxStore
    private let actorID: String

    public init(outbox: any OutboxStore, actorID: String) {
        self.outbox = outbox
        self.actorID = actorID
    }

    public func recordFolderCreated(_ folder: Folder) async throws {
        try await enqueue([
            MutationOperation(
                type: .createFolder,
                targetId: folder.id.description,
                payload: .object([
                    "name": .string(folder.name.rawValue),
                    "parentId": folder.parentFolderID.map { JSONValue.string($0.description) } ?? .null
                ])
            )
        ])
    }

    public func recordFolderRenamed(_ folderID: FolderID, name: FolderName) async throws {
        try await enqueue([
            MutationOperation(
                type: .renameFolder,
                targetId: folderID.description,
                payload: .object(["name": .string(name.rawValue)])
            )
        ])
    }

    public func recordAssetsMoved(_ assetIDs: Set<AssetID>, to folderID: FolderID) async throws {
        try await enqueue(orderedAssetIDs(assetIDs).map { assetID in
            MutationOperation(
                type: .moveAssets,
                targetId: assetID.description,
                payload: .object(["targetFolderId": .string(folderID.description)])
            )
        })
    }

    public func recordRatingChanged(_ rating: AssetRating, for assetIDs: Set<AssetID>) async throws {
        try await enqueue(orderedAssetIDs(assetIDs).map { assetID in
            MutationOperation(
                type: .updateRating,
                targetId: assetID.description,
                payload: .object(["rating": .number(Double(rating.rawValue))])
            )
        })
    }

    public func recordFavoriteChanged(_ favorite: Bool, for assetIDs: Set<AssetID>) async throws {
        try await enqueue(orderedAssetIDs(assetIDs).map { assetID in
            MutationOperation(
                type: .updateFavorite,
                targetId: assetID.description,
                payload: .object(["favorite": .bool(favorite)])
            )
        })
    }

    private func orderedAssetIDs(_ assetIDs: Set<AssetID>) -> [AssetID] {
        assetIDs.sorted { $0.description < $1.description }
    }

    private func enqueue(_ operations: [MutationOperation]) async throws {
        guard !operations.isEmpty else { return }
        try await outbox.enqueue(OutboxMutation(actorId: actorID, operations: operations))
    }
}
