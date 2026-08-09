import FramebaseAPIClient
import FramebaseDomain
import FramebaseSync
import Foundation

public enum CatalogChangeApplierError: Error, Equatable, Sendable {
    case invalidFolderID(String)
    case invalidAssetID(String)
    case missingPayloadField(String)
}

/// Applies a pulled `ChangeEvent` to a local catalog, undoing the encoding
/// `CatalogOutboxRecorder` performed on the origin device. Switches on
/// `event.operation` — the same five strings `Cloud/apps/api`'s
/// `mutations.ts` accepts — and ignores anything else, since this is a
/// change *consumer*, not a validator: a future server-side operation type
/// should be silently skipped by older clients, not crash them.
public struct CatalogChangeApplier: ChangeApplier {
    private let folders: any FolderRepository
    private let assets: any AssetRepository

    public init(folders: any FolderRepository, assets: any AssetRepository) {
        self.folders = folders
        self.assets = assets
    }

    public func apply(_ event: ChangeEvent) async throws {
        switch event.operation {
        case "create_folder":
            try await applyCreateFolder(event)
        case "rename_folder":
            try await applyRenameFolder(event)
        case "move_assets":
            try await applyMoveAssets(event)
        case "update_rating":
            try await applyUpdateRating(event)
        case "update_favorite":
            try await applyUpdateFavorite(event)
        default:
            break
        }
    }

    private func applyCreateFolder(_ event: ChangeEvent) async throws {
        let folderID = try Self.folderID(from: event.entityId)
        guard case .object(let fields) = event.payload, case .string(let name)? = fields["name"] else {
            throw CatalogChangeApplierError.missingPayloadField("name")
        }
        var parentFolderID: FolderID?
        if case .string(let parentIDText)? = fields["parentId"] {
            parentFolderID = try Self.folderID(from: parentIDText)
        }
        _ = try await folders.createFolder(id: folderID, named: try FolderName(name), in: parentFolderID)
    }

    private func applyRenameFolder(_ event: ChangeEvent) async throws {
        let folderID = try Self.folderID(from: event.entityId)
        guard case .object(let fields) = event.payload, case .string(let name)? = fields["name"] else {
            throw CatalogChangeApplierError.missingPayloadField("name")
        }
        try await folders.renameFolder(folderID, to: try FolderName(name))
    }

    private func applyMoveAssets(_ event: ChangeEvent) async throws {
        let assetID = try Self.assetID(from: event.entityId)
        guard case .object(let fields) = event.payload,
              case .string(let targetFolderIDText)? = fields["targetFolderId"] else {
            throw CatalogChangeApplierError.missingPayloadField("targetFolderId")
        }
        let targetFolderID = try Self.folderID(from: targetFolderIDText)
        try await assets.moveAssets([assetID], to: targetFolderID)
    }

    private func applyUpdateRating(_ event: ChangeEvent) async throws {
        let assetID = try Self.assetID(from: event.entityId)
        guard case .object(let fields) = event.payload, case .number(let ratingValue)? = fields["rating"] else {
            throw CatalogChangeApplierError.missingPayloadField("rating")
        }
        try await assets.updateRating(try AssetRating(Int(ratingValue)), for: [assetID])
    }

    private func applyUpdateFavorite(_ event: ChangeEvent) async throws {
        let assetID = try Self.assetID(from: event.entityId)
        guard case .object(let fields) = event.payload, case .bool(let favorite)? = fields["favorite"] else {
            throw CatalogChangeApplierError.missingPayloadField("favorite")
        }
        try await assets.updateFavorite(favorite, for: [assetID])
    }

    private static func folderID(from text: String) throws -> FolderID {
        guard let uuid = UUID(uuidString: text) else {
            throw CatalogChangeApplierError.invalidFolderID(text)
        }
        return FolderID(rawValue: uuid)
    }

    private static func assetID(from text: String) throws -> AssetID {
        guard let uuid = UUID(uuidString: text) else {
            throw CatalogChangeApplierError.invalidAssetID(text)
        }
        return AssetID(rawValue: uuid)
    }
}
