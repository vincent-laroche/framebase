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

    @Test("Blob migration preserves existing Asset identity and immutable local storage")
    func blobMigrationPreservesExistingAssets() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset, originalAvailable: true)

        try await database.databasePool.write { db in
            try db.execute(sql: "DROP TABLE asset_blobs")
            try db.execute(sql: "DROP TABLE blobs")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [FramebaseCatalogFoundation.blobMigrationIdentifier]
            )
        }
        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)

        let persisted = try reopened.databasePool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, storage_key, original_available FROM assets WHERE id = ?",
                arguments: [asset.id.description]
            )
        }
        #expect(persisted?["id"] as String? == asset.id.description)
        #expect(persisted?["storage_key"] as String? == asset.storageKey.rawValue)
        #expect(persisted?["original_available"] as Bool? == true)

        let tables = try await reopened.databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("blobs"))
        #expect(tables.contains("asset_blobs"))
    }

    @Test("A verified Blob can be registered and linked without changing an Asset storage key")
    func blobAssociationPreservesLocalAssetIdentity() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let blob = Blob(
            sha256: String(repeating: "a", count: 64),
            byteSize: asset.fileSize,
            mediaType: "image/jpeg",
            originalExtension: "jpg",
            r2Key: "blobs/sha256/aa/\(String(repeating: "a", count: 64)).jpg",
            uploadState: .verified,
            verificationETag: "fixture-etag",
            verifiedAt: FixtureFactory.fixedDate,
            createdAt: FixtureFactory.fixedDate
        )

        try await database.blobs.register(blob)
        try await database.blobs.link(assetID: asset.id, toBlobSHA256: blob.sha256)

        #expect(try await database.blobs.blob(sha256: blob.sha256) == blob)
        #expect(try await database.blobs.blobSHA256(for: asset.id) == blob.sha256)
        let persisted = try await database.databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT storage_key FROM assets WHERE id = ?", arguments: [asset.id.description])
        }
        #expect(persisted == asset.storageKey.rawValue)
    }

    @Test("Duplicate candidates are checksum evidence only")
    func checksumDuplicateCandidates() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let first = try makeAsset(parentFolderID: database.inboxID)
        let second = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAssets([first, second])
        let digest = String(repeating: "b", count: 64)
        let blob = Blob(sha256: digest, byteSize: first.fileSize, mediaType: "image/jpeg", originalExtension: "jpg", r2Key: "fixture", uploadState: .verified, verificationETag: nil, verifiedAt: nil, createdAt: FixtureFactory.fixedDate)
        try await database.blobs.register(blob)
        try await database.blobs.link(assetID: first.id, toBlobSHA256: digest)
        try await database.blobs.link(assetID: second.id, toBlobSHA256: digest)

        let candidates = try await database.blobs.duplicateCandidates()
        #expect(candidates == [DuplicateCandidate(sha256: digest, assetIDs: [first.id, second.id].sorted { $0.description < $1.description })])
        #expect(try await database.assets.asset(id: first.id)?.storageKey == first.storageKey)
        #expect(try await database.assets.asset(id: second.id)?.storageKey == second.storageKey)
    }

    @Test("Tag migration preserves existing assets and bulk membership is transactional")
    func tagsPreserveAssetsAndApplyAtomically() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset, originalAvailable: true)
        let tag = try await database.tags.createTag(named: "Reference")
        try await database.tags.addTags([tag.id], to: [asset.id])
        try await database.tags.addTags([tag.id], to: [asset.id])
        let count = try await database.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tags WHERE asset_id = ? AND tag_id = ?", arguments: [asset.id.description, tag.id.description])
        }
        #expect(count == 1)

        do {
            try await database.tags.addTags([tag.id, TagID()], to: [asset.id])
            Issue.record("Expected invalid TagID to reject the full bulk operation")
        } catch { }
        let unchanged = try await database.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tags WHERE asset_id = ?", arguments: [asset.id.description])
        }
        #expect(unchanged == 1)
        try await database.tags.removeTags([tag.id], from: [asset.id])
        let removed = try await database.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tags WHERE asset_id = ?", arguments: [asset.id.description])
        }
        #expect(removed == 0)
        #expect(try await database.assets.asset(id: asset.id)?.storageKey == asset.storageKey)
    }

    @Test("Tag migration upgrades a historical v2 catalog without changing existing library state")
    func tagMigrationPreservesHistoricalV2Catalog() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folder = try await database.folders.createFolder(named: FolderName("Existing Folder"), in: nil)
        let asset = try makeAsset(parentFolderID: folder.id)
        try await database.insertAsset(asset, originalAvailable: false)
        let album = try await database.createAlbum(named: "Existing Album")
        try await database.albums.addAssets([asset.id], to: album.id)
        let originalCatalogID = database.catalogID
        try await database.databasePool.write { db in
            try db.execute(sql: "DROP TABLE asset_tags")
            try db.execute(sql: "DROP TABLE tags")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [FramebaseCatalogFoundation.tagMigrationIdentifier])
        }

        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)

        #expect(reopened.catalogID == originalCatalogID)
        #expect(reopened.inboxID == database.inboxID)
        #expect(try await reopened.assets.asset(id: asset.id)?.storageKey == asset.storageKey)
        #expect(try await reopened.assets.asset(id: asset.id)?.parentFolderID == folder.id)
        #expect(try await reopened.folders.treeSnapshot().folders.contains(where: { $0.id == folder.id }))
        #expect(try await reopened.albums.albums().map(\.id) == [album.id])
        let originalAvailability = try await reopened.databasePool.read { db in
            try Bool.fetchOne(db, sql: "SELECT original_available FROM assets WHERE id = ?", arguments: [asset.id.description])
        }
        #expect(originalAvailability == false)
        let tables = try await reopened.databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("tags"))
        #expect(tables.contains("asset_tags"))
    }

    @Test("Tags normalize names, rename, and delete their logical memberships")
    func tagLifecycle() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)

        let tag = try await database.tags.createTag(named: "  Campaign  ")
        #expect(tag.name == "Campaign")
        try await database.tags.addTags([tag.id], to: [asset.id])
        try await database.tags.renameTag(tag.id, to: "Featured")
        #expect(try await database.tags.tags().map(\.name) == ["Featured"])

        let receipt = try await database.tags.deleteTag(tag.id)
        #expect(try await database.tags.tags().isEmpty)
        let membershipCount = try await database.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tags") ?? 0
        }
        #expect(membershipCount == 0)
        #expect(try await database.assets.asset(id: asset.id)?.storageKey == asset.storageKey)

        try await database.tags.restoreDeletedTag(using: receipt)
        #expect(try await database.tags.tags().map(\.name) == ["Featured"])
        let restoredMembershipCount = try await database.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tags") ?? 0
        }
        #expect(restoredMembershipCount == 1)
    }

    @Test("Local trash hides assets without changing their original identity and restores atomically")
    func localTrashAndRestore() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folder = try await database.folders.createFolder(named: FolderName("Reference"), in: nil)
        let first = try makeAsset(parentFolderID: folder.id)
        let second = try makeAsset(parentFolderID: folder.id)
        try await database.insertAssets([first, second])

        let receipt = try await database.assets.moveToTrash([first.id, second.id], retentionDays: 30)
        #expect(Set(receipt.entries.map(\.assetID)) == [first.id, second.id])
        let persistedEntries = try await database.assets.trashEntries(assetIDs: [first.id, second.id])
        #expect(persistedEntries.map(\.assetID) == [first.id, second.id].sorted { $0.description < $1.description })
        #expect(persistedEntries.allSatisfy { $0.expiresAt > $0.trashedAt })
        #expect(try await database.assets.count(matching: AssetQuery(scope: .allAssets)) == 0)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .trash)) == 2)
        #expect(try await database.assets.asset(id: first.id)?.storageKey == first.storageKey)
        #expect(try await database.assets.asset(id: second.id)?.parentFolderID == folder.id)

        try await database.assets.restoreFromTrash(using: receipt)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .allAssets)) == 2)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .trash)) == 0)
    }

    @Test("Logical asset moves create an exact undo receipt without changing originals")
    func assetMoveReceiptRestoresPriorFolders() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let source = try await database.folders.createFolder(named: FolderName("Source"), in: nil)
        let destination = try await database.folders.createFolder(named: FolderName("Destination"), in: nil)
        let asset = try makeAsset(parentFolderID: source.id)
        try await database.insertAsset(asset)

        let receipt = try await database.assets.moveAssetsWithReceipt([asset.id], to: destination.id)
        #expect(receipt.priorFolderByAssetID == [asset.id: source.id])
        #expect(try await database.assets.asset(id: asset.id)?.parentFolderID == destination.id)
        #expect(try await database.assets.asset(id: asset.id)?.storageKey == asset.storageKey)

        let redoReceipt = try await database.assets.restoreAssetLocations(using: receipt)
        #expect(redoReceipt.priorFolderByAssetID == [asset.id: destination.id])
        #expect(try await database.assets.asset(id: asset.id)?.parentFolderID == source.id)
        #expect(try await database.assets.asset(id: asset.id)?.storageKey == asset.storageKey)
    }

    @Test("Tag bulk mutations reject invalid assets without changing membership")
    func tagBulkMutationRejectsInvalidAsset() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let tag = try await database.tags.createTag(named: "Reference")

        do {
            try await database.tags.addTags([tag.id], to: [asset.id, AssetID()])
            Issue.record("Expected invalid AssetID to reject the full bulk operation")
        } catch { }
        let membershipCount = try await database.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tags") ?? 0
        }
        #expect(membershipCount == 0)
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

        let allAssetIDs = Set(assets.map(\.id))
        try await database.assets.updateFavorite(true, for: allAssetIDs)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .favorites)) == 510)
        try await database.assets.updateFavorite(false, for: allAssetIDs)

        let chosen = assets[42]
        let tag = try await database.tags.createTag(named: "Selected")
        try await database.tags.addTags([tag.id], to: [chosen.id])
        #expect(try await database.assets.count(matching: AssetQuery(scope: .tag(tag.id))) == 1)
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
        let batchDetails = try await database.assets.assets(ids: [chosen.id, assets[43].id])
        #expect(Set(batchDetails.map(\.id)) == [chosen.id, assets[43].id])
        let movedPage = try await database.assets.page(
            matching: AssetQuery(scope: .folder(folderB.id)),
            sortedBy: .defaultSort,
            offset: 0,
            limit: 500
        )
        #expect(movedPage.records.first?.originalAvailable == false)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .favorites)) == 1)
    }

    @Test("Structured asset search combines indexed catalog fields without changing asset identity")
    func structuredAssetSearch() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let marketing = try await database.folders.createFolder(named: FolderName("Marketing"), in: nil)
        let campaigns = try await database.folders.createFolder(named: FolderName("Campaigns"), in: marketing.id)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var matching = try makeAsset(
            parentFolderID: campaigns.id,
            filename: "hero-portrait.jpg",
            importedAt: capturedAt
        )
        matching.displayName = "Summer Hero"
        matching.favorite = true
        matching.rating = try AssetRating(5)
        matching.metadata = AssetMetadata(
            file: FileMetadata(filenameExtension: "jpg", typeIdentifier: "public.jpeg", mimeType: "image/jpeg"),
            image: ImageMetadata(pixelWidth: 1_200, pixelHeight: 800, colorModel: "RGB"),
            exif: EXIFMetadata(capturedAt: capturedAt, cameraMake: "Leica", cameraModel: "Q3")
        )
        let nonMatching = try makeAsset(parentFolderID: campaigns.id, filename: "detail.jpg", importedAt: capturedAt)
        try await database.insertAssets([matching, nonMatching])
        let album = try await database.albums.createAlbum(named: "Summer Launch")
        let tag = try await database.tags.createTag(named: "Hero")
        try await database.albums.addAssets([matching.id], to: album.id)
        try await database.tags.addTags([tag.id], to: [matching.id])

        let criteria = AssetSearchCriteria(
            text: "summer",
            folderPathText: "marketing/campaigns",
            metadataText: "Leica",
            capturedDateRange: AssetDateRange(start: capturedAt, end: capturedAt),
            rating: try AssetRating(5),
            favorite: true,
            tagIDs: [tag.id],
            albumIDs: [album.id]
        )
        let query = AssetQuery(scope: .allAssets, criteria: criteria)
        let page = try await database.assets.page(
            matching: query,
            sortedBy: AssetSort(key: .displayName, direction: .ascending),
            offset: 0,
            limit: 10
        )

        #expect(page.totalCount == 1)
        #expect(page.records.map(\.id) == [matching.id])
        #expect(try await database.assets.asset(id: matching.id)?.storageKey == matching.storageKey)
    }

    @Test("Saved search rules survive catalog reopen and return their structured query")
    func savedSearchPersistence() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let query = AssetQuery(
            scope: .favorites,
            criteria: AssetSearchCriteria(text: "summer", favorite: true)
        )

        let saved = try await database.savedSearches.createSavedSearch(named: "Summer Favorites", query: query)
        try await database.savedSearches.renameSavedSearch(saved.id, to: "Pinned Summer")
        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)

        let persisted = try #require(try await reopened.savedSearches.savedSearches().first)
        #expect(persisted.id == saved.id)
        #expect(persisted.name == "Pinned Summer")
        #expect(persisted.query == query)
    }

    @Test("Smart-collection migration upgrades a historical v6 catalog without changing existing state")
    func smartCollectionMigrationPreservesHistoricalV6Catalog() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folder = try await database.folders.createFolder(named: FolderName("Existing Folder"), in: nil)
        let asset = try makeAsset(parentFolderID: folder.id)
        try await database.insertAsset(asset, originalAvailable: false)
        let savedQuery = AssetQuery(scope: .folder(folder.id), criteria: AssetSearchCriteria(text: "existing"))
        let savedSearch = try await database.savedSearches.createSavedSearch(named: "Existing Rule", query: savedQuery)
        let originalCatalogID = database.catalogID

        try await database.databasePool.write { db in
            try db.execute(sql: "DROP TABLE smart_collections")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: [FramebaseCatalogFoundation.smartCollectionMigrationIdentifier]
            )
        }

        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)
        #expect(reopened.catalogID == originalCatalogID)
        #expect(reopened.inboxID == database.inboxID)
        #expect(try await reopened.assets.asset(id: asset.id)?.storageKey == asset.storageKey)
        #expect(try await reopened.assets.asset(id: asset.id)?.parentFolderID == folder.id)
        #expect(try await reopened.folders.treeSnapshot().folders.contains(where: { $0.id == folder.id }))
        #expect(try await reopened.savedSearches.savedSearches().map(\.id) == [savedSearch.id])
        #expect(try await reopened.smartCollections.smartCollections().isEmpty)
        let tables = try await reopened.databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("smart_collections"))
    }

    @Test("Smart collections persist their rules and resolve members without materializing asset state")
    func smartCollectionPersistenceAndMembership() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let matching = try makeAsset(parentFolderID: database.inboxID)
        let nonMatching = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAssets([matching, nonMatching])
        try await database.assets.updateFavorite(true, for: [matching.id])

        let query = AssetQuery(scope: .allAssets, criteria: AssetSearchCriteria(favorite: true))
        let smartCollection = try await database.smartCollections.createSmartCollection(
            named: "Favorites Rule",
            query: query
        )
        let matchingPage = try await database.assets.page(
            matching: smartCollection.query,
            sortedBy: .defaultSort,
            offset: 0,
            limit: 20
        )
        #expect(matchingPage.records.map(\.id) == [matching.id])
        #expect(try await database.assets.asset(id: nonMatching.id)?.storageKey == nonMatching.storageKey)

        try await database.smartCollections.renameSmartCollection(smartCollection.id, to: "Pinned Favorites")
        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)
        let persisted = try #require(try await reopened.smartCollections.smartCollections().first)
        #expect(persisted.id == smartCollection.id)
        #expect(persisted.name == "Pinned Favorites")
        #expect(persisted.query == query)

        try await reopened.smartCollections.deleteSmartCollection(persisted.id)
        #expect(try await reopened.smartCollections.smartCollections().isEmpty)
        #expect(try await reopened.assets.asset(id: matching.id)?.storageKey == matching.storageKey)
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

    @Test("A 100,000-asset catalog pages and sorts within the local acceptance budget")
    func largeCatalogPerformance() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let metadataData = try JSONEncoder().encode(AssetMetadata())
        let metadataJSON = try #require(String(data: metadataData, encoding: .utf8))

        try await database.databasePool.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO assets (
                    id, filename, display_name, parent_folder_id, storage_key, media_type,
                    width, height, file_size, created_at_ms, modified_at_ms, imported_at_ms,
                    updated_at_ms, favorite, rating, metadata_json, original_available
                ) VALUES (?, ?, ?, ?, ?, 'stillImage', 1200, 800, ?, ?, ?, ?, ?, 0, 0, ?, 1)
                """)
            for index in 0..<100_000 {
                let id = UUID().uuidString.lowercased()
                let name = String(format: "asset-%06d.jpg", index)
                try statement.execute(arguments: [
                    id,
                    name,
                    name,
                    database.inboxID.description,
                    "\(id.prefix(2))/\(id).jpg",
                    1_000 + index,
                    index,
                    index,
                    index,
                    index,
                    metadataJSON
                ])
            }
        }

        let clock = ContinuousClock()
        let pageStart = clock.now
        let page = try await database.assets.page(
            matching: AssetQuery(scope: .allAssets),
            sortedBy: .defaultSort,
            offset: 0,
            limit: 200
        )
        let pageDuration = pageStart.duration(to: clock.now)
        #expect(page.records.count == 200)
        #expect(page.totalCount == 100_000)
        #expect(pageDuration < .seconds(2))

        let sortStart = clock.now
        let ids = try await database.assets.orderedIDs(
            matching: AssetQuery(scope: .allAssets),
            sortedBy: AssetSort(key: .displayName, direction: .descending)
        )
        let sortDuration = sortStart.duration(to: clock.now)
        #expect(ids.count == 100_000)
        #expect(sortDuration < .seconds(2))
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

    @Test("Album reorder requires an exact permutation and persists atomically")
    func albumReorderPersistsAtomically() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let first = try await database.albums.createAlbum(named: "First")
        let second = try await database.albums.createAlbum(named: "Second")
        let third = try await database.albums.createAlbum(named: "Third")

        try await database.albums.reorderAlbums([third.id, first.id, second.id])
        #expect(try await database.albums.albums().map(\.id) == [third.id, first.id, second.id])

        do {
            try await database.albums.reorderAlbums([first.id, third.id])
            Issue.record("A missing album must reject the complete reorder")
        } catch CatalogError.invalidAlbumOrder { }
        catch {
            Issue.record("Unexpected reorder error: \(error)")
        }
        #expect(try await database.albums.albums().map(\.id) == [third.id, first.id, second.id])

        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)
        #expect(try await reopened.albums.albums().map(\.id) == [third.id, first.id, second.id])
    }

    @Test("Album deletion receipt restores the album and its logical memberships")
    func albumDeletionReceiptRestoresMemberships() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folder = try await database.folders.createFolder(named: FolderName("Source"), in: nil)
        let first = try makeAsset(parentFolderID: folder.id)
        let second = try makeAsset(parentFolderID: folder.id)
        try await database.insertAssets([first, second])
        let album = try await database.albums.createAlbum(named: "Campaign")
        try await database.albums.addAssets([first.id, second.id], to: album.id)
        let persistedAlbum = try #require(try await database.albums.albums().first)

        let receipt: AlbumDeletionReceipt = try await database.albums.deleteAlbum(album.id)
        #expect(receipt.album == persistedAlbum)
        let expectedMembershipIDs = [first.id, second.id].sorted { $0.description < $1.description }
        let restoredMembershipIDs = receipt.memberships.map(\.assetID).sorted { $0.description < $1.description }
        #expect(restoredMembershipIDs == expectedMembershipIDs)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .album(album.id))) == 0)
        #expect(try await database.assets.asset(id: first.id)?.storageKey == first.storageKey)
        #expect(try await database.assets.asset(id: second.id)?.storageKey == second.storageKey)

        try await database.albums.restoreDeletedAlbum(using: receipt)
        #expect(try await database.albums.albums().contains(persistedAlbum))
        #expect(try await database.assets.count(matching: AssetQuery(scope: .album(album.id))) == 2)
    }

    @Test("Folder, album, and tag observations publish committed snapshots")
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

        var tagIterator = database.tags.observeTags().makeAsyncIterator()
        let initialTags = try #require(try await tagIterator.next())
        #expect(initialTags.isEmpty)
        let tag = try await database.tags.createTag(named: "Observed Tag")
        let changedTags = try #require(try await tagIterator.next())
        #expect(changedTags.map(\.id) == [tag.id])

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
