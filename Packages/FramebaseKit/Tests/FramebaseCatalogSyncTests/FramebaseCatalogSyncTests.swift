import FramebaseAPIClient
import FramebaseCatalog
import FramebaseCatalogSync
import FramebaseDomain
import FramebaseSync
import FramebaseTestSupport
import Foundation
import Testing

private final class TemporaryCatalog {
    let directoryURL: URL
    let databaseURL: URL
    let database: CatalogDatabase

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "FramebaseCatalogSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
        database = try CatalogDatabase(catalogURL: databaseURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class TemporarySyncState {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "FramebaseCatalogSyncTests-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appending(path: "sync.sqlite", directoryHint: .notDirectory)
    }

    func openStore() throws -> SyncStateStore {
        try SyncStateStore(databaseURL: databaseURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private extension FolderTreeSnapshot {
    func folder(_ id: FolderID) -> Folder? {
        folders.first { $0.id == id }
    }
}

private func changeEvent(
    revision: Int,
    entityType: String,
    entityId: String,
    operation: String,
    payload: JSONValue
) -> ChangeEvent {
    ChangeEvent(
        revision: revision,
        entityType: entityType,
        entityId: entityId,
        operation: operation,
        payload: payload,
        actorId: "test-actor",
        clientMutationId: nil,
        createdAt: "2026-08-09T12:00:00.000Z"
    )
}

@Suite("CatalogChangeApplier", .serialized)
struct CatalogChangeApplierTests {
    @Test("create_folder creates a folder under the exact ID the event names")
    func createFolderAppliesWithExactID() async throws {
        let temporary = try TemporaryCatalog()
        let applier = CatalogChangeApplier(folders: temporary.database.folders, assets: temporary.database.assets, ownActorID: "device-under-test")
        let folderID = FolderID()

        try await applier.apply(changeEvent(
            revision: 1,
            entityType: "folder",
            entityId: folderID.description,
            operation: "create_folder",
            payload: .object(["name": .string("Vacation"), "parentId": .null])
        ))

        let snapshot = try await temporary.database.folders.treeSnapshot()
        let created = try #require(snapshot.folder(folderID))
        #expect(created.name.rawValue == "Vacation")
        #expect(created.parentFolderID == nil)
    }

    @Test("create_folder under a parent nests correctly")
    func createFolderAppliesUnderParent() async throws {
        let temporary = try TemporaryCatalog()
        let applier = CatalogChangeApplier(folders: temporary.database.folders, assets: temporary.database.assets, ownActorID: "device-under-test")
        let parentID = try await temporary.database.folders.createFolder(named: FolderName("Trips"), in: nil).id
        let childID = FolderID()

        try await applier.apply(changeEvent(
            revision: 2,
            entityType: "folder",
            entityId: childID.description,
            operation: "create_folder",
            payload: .object(["name": .string("2026"), "parentId": .string(parentID.description)])
        ))

        let snapshot = try await temporary.database.folders.treeSnapshot()
        let created = try #require(snapshot.folder(childID))
        #expect(created.parentFolderID == parentID)
    }

    @Test("rename_folder applies")
    func renameFolderApplies() async throws {
        let temporary = try TemporaryCatalog()
        let folder = try await temporary.database.folders.createFolder(named: FolderName("Old Name"), in: nil)
        let applier = CatalogChangeApplier(folders: temporary.database.folders, assets: temporary.database.assets, ownActorID: "device-under-test")

        try await applier.apply(changeEvent(
            revision: 3,
            entityType: "folder",
            entityId: folder.id.description,
            operation: "rename_folder",
            payload: .object(["name": .string("New Name")])
        ))

        let snapshot = try await temporary.database.folders.treeSnapshot()
        #expect(snapshot.folder(folder.id)?.name.rawValue == "New Name")
    }

    @Test("update_rating and update_favorite apply to an existing asset")
    func updateRatingAndFavoriteApply() async throws {
        let temporary = try TemporaryCatalog()
        let folder = try await temporary.database.folders.createFolder(named: FolderName("Photos"), in: nil)
        let asset = try FixtureFactory.asset(parentFolderID: folder.id)
        try await temporary.database.insertAsset(asset)
        let applier = CatalogChangeApplier(folders: temporary.database.folders, assets: temporary.database.assets, ownActorID: "device-under-test")

        try await applier.apply(changeEvent(
            revision: 4,
            entityType: "asset",
            entityId: asset.id.description,
            operation: "update_rating",
            payload: .object(["rating": .number(4)])
        ))
        try await applier.apply(changeEvent(
            revision: 5,
            entityType: "asset",
            entityId: asset.id.description,
            operation: "update_favorite",
            payload: .object(["favorite": .bool(true)])
        ))

        let updated = try #require(try await temporary.database.assets.asset(id: asset.id))
        #expect(updated.rating.rawValue == 4)
        #expect(updated.favorite == true)
    }

    @Test("move_assets applies")
    func moveAssetsApplies() async throws {
        let temporary = try TemporaryCatalog()
        let sourceFolder = try await temporary.database.folders.createFolder(named: FolderName("Source"), in: nil)
        let targetFolder = try await temporary.database.folders.createFolder(named: FolderName("Target"), in: nil)
        let asset = try FixtureFactory.asset(parentFolderID: sourceFolder.id)
        try await temporary.database.insertAsset(asset)
        let applier = CatalogChangeApplier(folders: temporary.database.folders, assets: temporary.database.assets, ownActorID: "device-under-test")

        try await applier.apply(changeEvent(
            revision: 6,
            entityType: "asset",
            entityId: asset.id.description,
            operation: "move_assets",
            payload: .object(["targetFolderId": .string(targetFolder.id.description)])
        ))

        let moved = try #require(try await temporary.database.assets.asset(id: asset.id))
        #expect(moved.parentFolderID == targetFolder.id)
    }

    @Test("An unrecognized operation is ignored rather than thrown")
    func unknownOperationIsIgnored() async throws {
        let temporary = try TemporaryCatalog()
        let applier = CatalogChangeApplier(folders: temporary.database.folders, assets: temporary.database.assets, ownActorID: "device-under-test")

        try await applier.apply(changeEvent(
            revision: 7,
            entityType: "asset",
            entityId: AssetID().description,
            operation: "future_operation_type",
            payload: .null
        ))
    }

    @Test("A malformed payload throws a typed error instead of crashing")
    func malformedPayloadThrows() async throws {
        let temporary = try TemporaryCatalog()
        let applier = CatalogChangeApplier(folders: temporary.database.folders, assets: temporary.database.assets, ownActorID: "device-under-test")

        await #expect(throws: CatalogChangeApplierError.missingPayloadField("name")) {
            try await applier.apply(changeEvent(
                revision: 8,
                entityType: "folder",
                entityId: FolderID().description,
                operation: "create_folder",
                payload: .object([:])
            ))
        }
    }
}

@Suite("Syncing repositories", .serialized)
struct SyncingRepositoryTests {
    @Test("Creating and renaming a folder through SyncingFolderRepository records matching outbox operations")
    func syncingFolderRepositoryRecordsOutbox() async throws {
        let catalog = try TemporaryCatalog()
        let syncState = try TemporarySyncState()
        let outbox = try syncState.openStore()
        let recorder = CatalogOutboxRecorder(outbox: outbox, actorID: "device-a")
        let repository = SyncingFolderRepository(wrapping: catalog.database.folders, recorder: recorder)

        let folder = try await repository.createFolder(named: FolderName("Vacation"), in: nil)
        try await repository.renameFolder(folder.id, to: FolderName("Vacation 2026"))

        let pending = try await outbox.pendingMutations()
        #expect(pending.count == 2)
        #expect(pending[0].operations.map(\.type) == [.createFolder])
        #expect(pending[0].operations[0].targetId == folder.id.description)
        #expect(pending[1].operations.map(\.type) == [.renameFolder])
        #expect(pending[1].operations[0].targetId == folder.id.description)
    }

    @Test("Rating, favoriting, and moving assets through SyncingAssetRepository records matching outbox operations")
    func syncingAssetRepositoryRecordsOutbox() async throws {
        let catalog = try TemporaryCatalog()
        let folder = try await catalog.database.folders.createFolder(named: FolderName("Photos"), in: nil)
        let targetFolder = try await catalog.database.folders.createFolder(named: FolderName("Target"), in: nil)
        let asset = try FixtureFactory.asset(parentFolderID: folder.id)
        try await catalog.database.insertAsset(asset)

        let syncState = try TemporarySyncState()
        let outbox = try syncState.openStore()
        let recorder = CatalogOutboxRecorder(outbox: outbox, actorID: "device-a")
        let repository = SyncingAssetRepository(wrapping: catalog.database.assets, recorder: recorder)

        try await repository.updateRating(try AssetRating(5), for: [asset.id])
        try await repository.updateFavorite(true, for: [asset.id])
        try await repository.moveAssets([asset.id], to: targetFolder.id)

        let pending = try await outbox.pendingMutations()
        #expect(pending.count == 3)
        #expect(pending[0].operations[0].type == .updateRating)
        #expect(pending[1].operations[0].type == .updateFavorite)
        #expect(pending[2].operations[0].type == .moveAssets)
        for mutation in pending {
            #expect(mutation.operations[0].targetId == asset.id.description)
        }
    }

    @Test("A push through the outbox round-trips to a second catalog via CatalogChangeApplier")
    func outboxOperationsRoundTripToASecondCatalog() async throws {
        let sourceCatalog = try TemporaryCatalog()
        let syncState = try TemporarySyncState()
        let outbox = try syncState.openStore()
        let recorder = CatalogOutboxRecorder(outbox: outbox, actorID: "device-a")
        let sourceFolders = SyncingFolderRepository(wrapping: sourceCatalog.database.folders, recorder: recorder)

        let folder = try await sourceFolders.createFolder(named: FolderName("Shared Folder"), in: nil)

        // Simulate what the server would echo back on the change feed: one
        // ChangeEvent per pushed MutationOperation, carrying the same
        // entityId/payload the outbox recorded.
        let pending = try await outbox.pendingMutations()
        let events = pending.enumerated().flatMap { index, mutation in
            mutation.operations.map { operation in
                changeEvent(
                    revision: index + 1,
                    entityType: "folder",
                    entityId: operation.targetId,
                    operation: operation.type.rawValue,
                    payload: operation.payload
                )
            }
        }

        let targetCatalog = try TemporaryCatalog()
        let applier = CatalogChangeApplier(folders: targetCatalog.database.folders, assets: targetCatalog.database.assets, ownActorID: "device-under-test")
        for event in events {
            try await applier.apply(event)
        }

        let snapshot = try await targetCatalog.database.folders.treeSnapshot()
        #expect(snapshot.folder(folder.id)?.name.rawValue == "Shared Folder")
    }
}
