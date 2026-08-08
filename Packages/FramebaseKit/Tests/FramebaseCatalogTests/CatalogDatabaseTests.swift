import Foundation
import FramebaseDomain
import FramebaseTestSupport
import GRDB
import Testing
@testable import FramebaseCatalog

@Suite("Catalog database", .serialized)
struct CatalogDatabaseTests {
    @Test("Migration seeds one Inbox and persistent catalog identity")
    func migrationAndReopen() throws {
        let temporary = try TemporaryCatalog()
        let first = temporary.database

        #expect(first.catalogURL == temporary.databaseURL)
        #expect(first.catalogID.description == first.catalogID.description.lowercased())
        #expect(first.inboxID.description == first.inboxID.description.lowercased())

        let state = try first.databasePool.read { db in
            let inboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM folders WHERE system_kind = 'inbox'"
            ) ?? 0
            let migrationCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                arguments: [FramebaseCatalogFoundation.migrationIdentifier]
            ) ?? 0
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
            let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
            return (inboxCount, migrationCount, journalMode, foreignKeys)
        }

        #expect(state.0 == 1)
        #expect(state.1 == 1)
        #expect(state.2?.lowercased() == "wal")
        #expect(state.3 == 1)

        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)
        #expect(reopened.catalogID == first.catalogID)
        #expect(reopened.inboxID == first.inboxID)
        let snapshot = try reopened.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders WHERE system_kind = 'inbox'") ?? 0
        }
        #expect(snapshot == 1)
    }

    @Test("Schema enforces identifiers, names, ratings, and foreign keys")
    func schemaConstraints() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folder = try await database.folders.createFolder(named: FolderName("Clients"), in: nil)
        let asset = try makeAsset(parentFolderID: folder.id)
        try await database.insertAsset(asset)

        await expectDatabaseFailure {
            try await database.databasePool.write { db in
                try db.execute(
                    sql: "UPDATE assets SET rating = 6 WHERE id = ?",
                    arguments: [asset.id.description]
                )
            }
        }

        await expectDatabaseFailure {
            try await database.databasePool.write { db in
                try db.execute(
                    sql: "UPDATE assets SET parent_folder_id = ? WHERE id = ?",
                    arguments: [FolderID().description, asset.id.description]
                )
            }
        }

        await expectDatabaseFailure {
            try await database.databasePool.write { db in
                try db.execute(
                    sql: "UPDATE folders SET id = upper(id) WHERE id = ?",
                    arguments: [folder.id.description]
                )
            }
        }

        _ = try await database.folders.createFolder(named: FolderName("Reference"), in: nil)
        await expectDatabaseFailure {
            _ = try await database.folders.createFolder(named: FolderName("reference"), in: nil)
        }

        let columns = try await database.databasePool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(assets)").map { row in
                (row["name"] as String, row["type"] as String)
            }
        }
        #expect(!columns.contains { $0.0.contains("thumbnail") || $0.0.contains("original_bytes") })
        #expect(!columns.contains { $0.1.uppercased() == "BLOB" })
    }

    @Test("Asset queries page, sort, scope, update, and resolve details")
    func assetQueriesAndMutations() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folderA = try await database.folders.createFolder(named: FolderName("A"), in: nil)
        let folderB = try await database.folders.createFolder(named: FolderName("B"), in: nil)
        var assets: [Asset] = []
        assets.reserveCapacity(510)
        for index in 0..<510 {
            var asset = try makeAsset(
                id: AssetID(),
                parentFolderID: folderA.id,
                filename: String(format: "image-%03d.jpg", 509 - index),
                importedAt: Date(timeIntervalSince1970: Double(index))
            )
            asset.displayName = asset.filename
            assets.append(asset)
        }
        try await database.insertAssets(assets)

        let query = AssetQuery(scope: .folder(folderA.id))
        #expect(try await database.assets.count(matching: query) == 510)
        let page = try await database.assets.page(
            matching: query,
            sortedBy: AssetSort(key: .displayName, direction: .ascending),
            offset: 0,
            limit: 1_000
        )
        #expect(page.records.count == 500)
        #expect(page.totalCount == 510)
        #expect(page.hasMore)
        #expect(page.records.first?.displayName == "image-000.jpg")

        let newest = try await database.assets.orderedIDs(
            matching: query,
            sortedBy: AssetSort(key: .importedAt, direction: .descending)
        )
        #expect(newest.first == assets.last?.id)

        let chosen = assets[42]
        try await database.assets.updateDisplayName("  Hero Portrait  ", for: chosen.id)
        try await database.assets.updateFavorite(true, for: [chosen.id])
        try await database.assets.updateRating(AssetRating(5), for: [chosen.id])
        try await database.assets.moveAssets([chosen.id], to: folderB.id)
        try await database.setOriginalAvailable(false, for: chosen.id)

        let detail = try #require(try await database.assets.asset(id: chosen.id))
        #expect(detail.displayName == "Hero Portrait")
        #expect(detail.favorite)
        #expect(detail.rating.rawValue == 5)
        #expect(detail.parentFolderID == folderB.id)
        #expect(detail.localURL == nil)
        let movedPage = try await database.assets.page(
            matching: AssetQuery(scope: .folder(folderB.id)),
            sortedBy: .defaultSort,
            offset: 0,
            limit: 500
        )
        #expect(movedPage.records.first?.originalAvailable == false)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .favorites)) == 1)
    }

    @Test("Asset batch insertion is atomic")
    func batchInsertionRollback() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let valid = try makeAsset(parentFolderID: database.inboxID)
        let invalid = try makeAsset(parentFolderID: FolderID())

        await expectDatabaseFailure {
            try await database.insertAssets([valid, invalid])
        }
        #expect(try await database.assets.count(matching: AssetQuery(scope: .allAssets)) == 0)
    }

    @Test("Folder operations reject cycles and preserve assets through delete and restore")
    func folderTreeDeletionAndRestore() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let root = try await database.folders.createFolder(named: FolderName("Root"), in: nil)
        let child = try await database.folders.createFolder(named: FolderName("Child"), in: root.id)
        let other = try await database.folders.createFolder(named: FolderName("Other"), in: nil)
        try await database.folders.renameFolder(other.id, to: FolderName("Archive"))
        try await database.folders.reparentFolder(other.id, to: root.id)

        let beforeDeletion = try await database.folders.treeSnapshot()
        let expectedDeletedFolders = Dictionary(
            uniqueKeysWithValues: beforeDeletion.folders
                .filter { [root.id, child.id, other.id].contains($0.id) }
                .map { ($0.id, $0) }
        )

        do {
            try await database.folders.reparentFolder(root.id, to: child.id)
            Issue.record("Expected descendant cycle rejection")
        } catch {
            #expect(error as? CatalogError == CatalogError.folderCycle)
        }
        do {
            try await database.folders.reparentFolder(database.inboxID, to: root.id)
            Issue.record("Expected Inbox mutation rejection")
        } catch {
            #expect(error as? CatalogError == CatalogError.systemFolderImmutable(database.inboxID))
        }

        let rootAsset = try makeAsset(parentFolderID: root.id)
        let childAsset = try makeAsset(parentFolderID: child.id)
        try await database.insertAssets([rootAsset, childAsset])
        let receipt = try await database.folders.deletePreservingAssets(root.id)

        #expect(Set(receipt.deletedFolders.map(\.id)) == [root.id, child.id, other.id])
        #expect(Dictionary(uniqueKeysWithValues: receipt.deletedFolders.map { ($0.id, $0) }) == expectedDeletedFolders)
        #expect(receipt.priorAssetAssignments[rootAsset.id] == root.id)
        #expect(receipt.priorAssetAssignments[childAsset.id] == child.id)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .inbox)) == 2)
        let deletedSnapshot = try await database.folders.treeSnapshot()
        #expect(!deletedSnapshot.folders.contains { $0.id == root.id })

        try await database.folders.restoreDeletedFolder(using: receipt)
        let restoredSnapshot = try await database.folders.treeSnapshot()
        #expect(restoredSnapshot.childrenByParent[root.id] == [child.id, other.id])
        #expect(try await database.assets.asset(id: rootAsset.id)?.parentFolderID == root.id)
        #expect(try await database.assets.asset(id: childAsset.id)?.parentFolderID == child.id)
    }

    @Test("Folder mutations reject invalid parents and every Inbox mutation")
    func folderInvalidParentsAndInboxImmutability() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let root = try await database.folders.createFolder(named: FolderName("Root"), in: nil)
        let missing = FolderID()

        do {
            _ = try await database.folders.createFolder(named: FolderName("Orphan"), in: missing)
            Issue.record("Expected invalid create parent rejection")
        } catch {
            #expect(error as? CatalogError == .invalidFolderParent(missing))
        }
        do {
            try await database.folders.reparentFolder(root.id, to: missing)
            Issue.record("Expected invalid reparent target rejection")
        } catch {
            #expect(error as? CatalogError == .invalidFolderParent(missing))
        }
        do {
            _ = try await database.folders.createFolder(named: FolderName("Inside Inbox"), in: database.inboxID)
            Issue.record("Expected Inbox child rejection")
        } catch {
            #expect(error as? CatalogError == .invalidFolderParent(database.inboxID))
        }
        do {
            try await database.folders.renameFolder(database.inboxID, to: FolderName("Renamed"))
            Issue.record("Expected Inbox rename rejection")
        } catch {
            #expect(error as? CatalogError == .systemFolderImmutable(database.inboxID))
        }
        do {
            _ = try await database.folders.deletePreservingAssets(database.inboxID)
            Issue.record("Expected Inbox deletion rejection")
        } catch {
            #expect(error as? CatalogError == .systemFolderImmutable(database.inboxID))
        }
        do {
            try await database.folders.reparentFolder(root.id, to: root.id)
            Issue.record("Expected self-parenting rejection")
        } catch {
            #expect(error as? CatalogError == .folderCycle)
        }

        let snapshot = try await database.folders.treeSnapshot()
        #expect(snapshot.roots == [root.id])
        #expect(snapshot.folders.first(where: { $0.id == database.inboxID })?.name.rawValue == "Inbox")
    }

    @Test("Sibling uniqueness and no-op reparenting preserve existing state")
    func folderSiblingUniquenessAndNoOp() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let firstRoot = try await database.folders.createFolder(named: FolderName("First"), in: nil)
        let secondRoot = try await database.folders.createFolder(named: FolderName("Second"), in: nil)
        let firstChild = try await database.folders.createFolder(named: FolderName("Shared"), in: firstRoot.id)
        let secondChild = try await database.folders.createFolder(named: FolderName("shared"), in: secondRoot.id)

        await expectDatabaseFailure {
            _ = try await database.folders.createFolder(named: FolderName("SHARED"), in: firstRoot.id)
        }
        await expectDatabaseFailure {
            try await database.folders.renameFolder(secondRoot.id, to: FolderName("first"))
        }
        await expectDatabaseFailure {
            try await database.folders.reparentFolder(secondChild.id, to: firstRoot.id)
        }

        let beforeNoOp = try #require(
            try await database.folders.treeSnapshot().folders.first(where: { $0.id == firstChild.id })
        )
        try await database.folders.reparentFolder(firstChild.id, to: firstRoot.id)
        let afterNoOp = try #require(
            try await database.folders.treeSnapshot().folders.first(where: { $0.id == firstChild.id })
        )
        #expect(afterNoOp == beforeNoOp)

        let snapshot = try await database.folders.treeSnapshot()
        #expect(snapshot.roots == [firstRoot.id, secondRoot.id])
        #expect(snapshot.childrenByParent[firstRoot.id] == [firstChild.id])
        #expect(snapshot.childrenByParent[secondRoot.id] == [secondChild.id])
        #expect(snapshot.folders.first(where: { $0.id == secondRoot.id })?.name.rawValue == "Second")
    }

    @Test("Folder observations preserve gap-sort sibling ordering")
    func folderObservationOrdering() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        var iterator = database.folders.observeTree().makeAsyncIterator()
        _ = try #require(try await iterator.next())

        let firstRoot = try await database.folders.createFolder(named: FolderName("Zulu"), in: nil)
        let firstSnapshot = try #require(try await iterator.next())
        #expect(firstSnapshot.roots == [firstRoot.id])
        let secondRoot = try await database.folders.createFolder(named: FolderName("Alpha"), in: nil)
        let secondSnapshot = try #require(try await iterator.next())
        #expect(secondSnapshot.roots == [firstRoot.id, secondRoot.id])

        let firstChild = try await database.folders.createFolder(named: FolderName("Zulu Child"), in: firstRoot.id)
        _ = try #require(try await iterator.next())
        let secondChild = try await database.folders.createFolder(named: FolderName("Alpha Child"), in: firstRoot.id)
        let childrenSnapshot = try #require(try await iterator.next())
        #expect(childrenSnapshot.childrenByParent[firstRoot.id] == [firstChild.id, secondChild.id])

        try await database.folders.reparentFolder(secondChild.id, to: secondRoot.id)
        let reparentedSnapshot = try #require(try await iterator.next())
        #expect(reparentedSnapshot.childrenByParent[firstRoot.id] == [firstChild.id])
        #expect(reparentedSnapshot.childrenByParent[secondRoot.id] == [secondChild.id])
    }

    @Test("Failed folder restore rolls back the entire hierarchy")
    func restoreTransactionRollback() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let root = try await database.folders.createFolder(named: FolderName("Jobs"), in: nil)
        _ = try await database.folders.createFolder(named: FolderName("Selected"), in: root.id)
        let asset = try makeAsset(parentFolderID: root.id)
        try await database.insertAsset(asset)
        let receipt = try await database.folders.deletePreservingAssets(root.id)
        _ = try await database.folders.createFolder(named: FolderName("jobs"), in: nil)

        await expectDatabaseFailure {
            try await database.folders.restoreDeletedFolder(using: receipt)
        }
        let snapshot = try await database.folders.treeSnapshot()
        #expect(!snapshot.folders.contains { $0.id == root.id })
        #expect(try await database.assets.asset(id: asset.id)?.parentFolderID == database.inboxID)
    }

    @Test("Albums maintain independent membership and cascade memberships")
    func albumMembership() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folder = try await database.folders.createFolder(named: FolderName("Source"), in: nil)
        let first = try makeAsset(parentFolderID: folder.id)
        let second = try makeAsset(parentFolderID: folder.id)
        try await database.insertAssets([first, second])
        let album = try await database.createAlbum(named: "Campaign")

        try await database.albums.addAssets([first.id, second.id], to: album.id)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .album(album.id))) == 2)
        #expect(try await database.assets.asset(id: first.id)?.parentFolderID == folder.id)
        try await database.albums.removeAssets([first.id], from: album.id)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .album(album.id))) == 1)

        try await database.databasePool.write { db in
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [album.id.description])
        }
        let membershipCount = try await database.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_assets") ?? 0
        }
        #expect(membershipCount == 0)
    }

    @Test("Folder and album observations publish committed snapshots")
    func observations() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database

        var folderIterator = database.folders.observeTree().makeAsyncIterator()
        let initialFolders = try #require(try await folderIterator.next())
        #expect(initialFolders.inboxID == database.inboxID)
        let folder = try await database.folders.createFolder(named: FolderName("Observed"), in: nil)
        let changedFolders = try #require(try await folderIterator.next())
        #expect(changedFolders.roots.contains(folder.id))

        var albumIterator = database.albums.observeAlbums().makeAsyncIterator()
        let initialAlbums = try #require(try await albumIterator.next())
        #expect(initialAlbums.isEmpty)
        let album = try await database.createAlbum(named: "Observed Album")
        let changedAlbums = try #require(try await albumIterator.next())
        #expect(changedAlbums.map(\.id) == [album.id])

        var assetIterator = database.assets
            .observe(matching: AssetQuery(scope: .allAssets))
            .makeAsyncIterator()
        let initialAssetChange = try #require(try await assetIterator.next())
        #expect(initialAssetChange.areas == [.assets])
        let asset = try makeAsset(parentFolderID: folder.id)
        try await database.insertAsset(asset)
        let insertedAssetChange = try #require(try await assetIterator.next())
        #expect(insertedAssetChange.areas == [.assets])

        try await database.assets.updateFavorite(true, for: [asset.id])
        let updatedAssetChange = try #require(try await assetIterator.next())
        #expect(updatedAssetChange.areas == [.assets])
    }
}

private final class TemporaryCatalog {
    let directoryURL: URL
    let databaseURL: URL
    let database: CatalogDatabase

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "FramebaseCatalogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
        database = try CatalogDatabase(catalogURL: databaseURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func makeAsset(
    id: AssetID = AssetID(),
    parentFolderID: FolderID,
    filename: String = "fixture.jpg",
    importedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> Asset {
    Asset(
        id: id,
        filename: filename,
        displayName: filename,
        parentFolderID: parentFolderID,
        storageKey: try AssetStorageKey("\(id.description.prefix(2))/\(id.description).jpg"),
        width: 1_200,
        height: 800,
        fileSize: 1_024,
        createdAt: importedAt,
        modifiedAt: importedAt,
        importedAt: importedAt,
        updatedAt: importedAt,
        metadata: AssetMetadata(image: ImageMetadata(pixelWidth: 1_200, pixelHeight: 800))
    )
}

private func expectDatabaseFailure(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected database operation to fail")
    } catch {
        #expect(error is DatabaseError)
    }
}
