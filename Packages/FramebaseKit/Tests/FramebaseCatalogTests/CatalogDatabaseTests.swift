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

    @Test("Legacy organization tables upgrade without losing memberships, searches, or Trash recovery state")
    func legacyOrganizationSchemaUpgrades() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folder = try await database.folders.createFolder(named: FolderName("Legacy folder"), in: nil)
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let tagID = TagID()
        let searchID = SavedSearchID()
        let now = Int64(1_700_000_000_000)
        let legacyQuery = #"""
            {"criteria":{"text":"portrait","folderPathText":"Legacy folder","capturedDateRange":null,"rating":null,"favorite":true,"tagIDs":[],"albumIDs":[]}}
            """#

        try await database.databasePool.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v4_complete_organization', 'v5_organization_cloud_parity')")
            try db.execute(sql: "DROP TABLE export_receipts")
            try db.execute(sql: "DROP TABLE backup_manifests")
            try db.execute(sql: "DROP TABLE asset_trash")
            try db.execute(sql: "DROP TABLE saved_searches")
            try db.execute(sql: "DROP TABLE asset_tags")
            try db.execute(sql: "DROP TABLE tags")
            try db.execute(sql: "DROP TABLE remote_entity_state")
            try db.execute(sql: """
                CREATE TABLE remote_entity_state (
                    entity_type TEXT NOT NULL CHECK(entity_type IN ('folder', 'album')),
                    entity_id TEXT NOT NULL CHECK(entity_id = lower(entity_id) AND length(entity_id) = 36),
                    remote_revision INTEGER NOT NULL CHECK(remote_revision >= 0),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(entity_type, entity_id)
                );
                CREATE INDEX remote_entity_state_revision_index
                    ON remote_entity_state(entity_type, remote_revision);
                CREATE TABLE tags (
                    id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
                    name TEXT NOT NULL COLLATE NOCASE CHECK(name = trim(name) AND length(name) BETWEEN 1 AND 255),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    sort_order INTEGER NOT NULL
                );
                CREATE UNIQUE INDEX tags_name_unique ON tags(name COLLATE NOCASE);
                CREATE TABLE asset_tags (
                    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE RESTRICT,
                    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
                    added_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(asset_id, tag_id)
                );
                CREATE INDEX asset_tags_tag_index ON asset_tags(tag_id, asset_id);
                CREATE TABLE saved_searches (
                    id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
                    name TEXT NOT NULL COLLATE NOCASE CHECK(name = trim(name) AND length(name) BETWEEN 1 AND 255),
                    query_json TEXT NOT NULL CHECK(json_valid(query_json)),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    sort_order INTEGER NOT NULL
                );
                CREATE UNIQUE INDEX saved_searches_name_unique ON saved_searches(name COLLATE NOCASE);
                CREATE INDEX saved_searches_sort_index ON saved_searches(sort_order, name COLLATE NOCASE, id);
                CREATE TABLE asset_trash (
                    asset_id TEXT PRIMARY KEY NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    prior_folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE RESTRICT,
                    trashed_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms >= trashed_at_ms)
                );
                CREATE INDEX asset_trash_expiry_index ON asset_trash(expires_at_ms, asset_id);
                """)
            try db.execute(
                sql: "INSERT INTO tags (id, name, created_at_ms, updated_at_ms, sort_order) VALUES (?, 'Client Work', ?, ?, 1024)",
                arguments: [tagID.description, now, now]
            )
            try db.execute(
                sql: "INSERT INTO asset_tags (asset_id, tag_id, added_at_ms) VALUES (?, ?, ?)",
                arguments: [asset.id.description, tagID.description, now]
            )
            try db.execute(
                sql: "INSERT INTO saved_searches (id, name, query_json, created_at_ms, updated_at_ms, sort_order) VALUES (?, 'Portraits', ?, ?, ?, 1024)",
                arguments: [searchID.description, legacyQuery, now, now]
            )
            try db.execute(
                sql: "INSERT INTO asset_trash (asset_id, prior_folder_id, trashed_at_ms, expires_at_ms) VALUES (?, ?, ?, ?)",
                arguments: [asset.id.description, folder.id.description, now, now + 86_400_000]
            )
        }

        let upgraded = try CatalogDatabase(catalogURL: temporary.databaseURL)
        let migratedTag = try #require(try await upgraded.tags.tags().first)
        #expect(migratedTag.id == tagID)
        #expect(migratedTag.name.rawValue == "legacy:client-work")
        let migratedSearch = try #require(try await upgraded.savedSearches.savedSearches().first)
        #expect(migratedSearch.id == searchID)
        #expect(migratedSearch.filter.text == "portrait")
        #expect(migratedSearch.filter.folderPath == "Legacy folder")
        #expect(migratedSearch.filter.favorite == true)
        #expect(try await upgraded.assets.trashedAssets(sortedBy: .defaultSort).records.map(\.id) == [asset.id])
        #expect((try await upgraded.tags.tags(for: [asset.id]))[asset.id]?.isEmpty ?? true)

        try await upgraded.assets.restoreAssets([asset.id])
        #expect(try await upgraded.assets.asset(id: asset.id)?.parentFolderID == folder.id)
        #expect((try await upgraded.tags.tags(for: [asset.id]))[asset.id]?.map(\.id) == [tagID])
        let migrationIdentifiers = try await upgraded.databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(migrationIdentifiers.contains("v4_complete_organization"))
        #expect(migrationIdentifiers.contains("v5_organization_cloud_parity"))
        #expect(migrationIdentifiers.contains("v6_receipt_cloud_parity"))
        #expect(migrationIdentifiers.contains("v7_backup_cloud_parity"))
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

    @Test("Tags, saved searches, scoped query filters, albums, and trash remain reversible")
    func organizationSearchAndTrash() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let products = try await database.folders.createFolder(named: FolderName("Products"), in: nil)
        let hero = try await database.folders.createFolder(named: FolderName("Hero"), in: products.id)
        var first = try makeAsset(parentFolderID: hero.id, filename: "alpha-hero.jpg")
        first.displayName = "Alpha Hero"
        first.metadata = AssetMetadata(exif: EXIFMetadata(cameraMake: "Canon", cameraModel: "R5"))
        var second = try makeAsset(parentFolderID: hero.id, filename: "beta-detail.jpg")
        second.displayName = "Beta Detail"
        second.createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        try await database.insertAssets([first, second])

        let productTag = try await database.tags.createTag(named: TagName("product:thin-skin-pro"))
        let statusTag = try await database.tags.createTag(named: TagName("status:review"))
        try await database.tags.addTags([productTag.id, statusTag.id], to: [first.id])
        #expect(try await database.tags.tags(for: [first.id])[first.id]?.map(\.name.rawValue) == ["product:thin-skin-pro", "status:review"])

        let album = try await database.albums.createAlbum(named: "Launch selects")
        try await database.albums.addAssets([first.id], to: album.id)
        try await database.albums.renameAlbum(album.id, to: "Launch Selects")
        let secondAlbum = try await database.albums.createAlbum(named: "Secondary")
        try await database.albums.reorderAlbum(secondAlbum.id, after: album.id)
        #expect(try await database.albums.albums().map(\.id) == [album.id, secondAlbum.id])

        let filter = AssetFilter(
            text: "canon",
            folderPath: "Products/Hero",
            tagIDs: [productTag.id, statusTag.id],
            albumIDs: [album.id],
            dateRange: first.createdAt...first.createdAt,
            rating: .unrated,
            favorite: false
        )
        let query = AssetQuery(scope: .allAssets, filter: filter)
        #expect(try await database.assets.orderedIDs(matching: query, sortedBy: .defaultSort) == [first.id])

        let search = SavedSearch(name: try SavedSearchName("Needs Review"), filter: filter)
        try await database.savedSearches.save(search)
        #expect(try await database.savedSearches.savedSearches().first?.filter == filter)

        let receipts = try await database.assets.trashAssets([first.id], retentionDays: 30)
        #expect(receipts.count == 1)
        #expect(receipts.first?.priorFolderID == hero.id)
        #expect(receipts.first?.albumIDs == [album.id])
        #expect(Set(receipts.first?.tagIDs ?? []) == [productTag.id, statusTag.id])
        #expect(try await database.assets.count(matching: AssetQuery(scope: .allAssets)) == 1)
        #expect(try await database.assets.trashedAssets(sortedBy: .defaultSort).records.map(\.id) == [first.id])

        let transientAlbum = try await database.albums.createAlbum(named: "Temporary trash edits")
        let transientTag = try await database.tags.createTag(named: TagName("campaign:temporary"))
        try await database.albums.addAssets([first.id], to: transientAlbum.id)
        try await database.tags.addTags([transientTag.id], to: [first.id])

        try await database.assets.restoreAssets([first.id])
        #expect(try await database.assets.asset(id: first.id)?.parentFolderID == hero.id)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .allAssets)) == 2)
        #expect(Set(try await database.tags.tags(for: [first.id])[first.id]?.map(\.id) ?? []) == [productTag.id, statusTag.id])
        #expect(try await database.assets.orderedIDs(matching: AssetQuery(scope: .album(album.id)), sortedBy: .defaultSort) == [first.id])
        #expect(try await database.assets.orderedIDs(matching: AssetQuery(scope: .album(transientAlbum.id)), sortedBy: .defaultSort).isEmpty)

        let approvedTag = try await database.tags.createTag(named: TagName("status:approved"))
        try await database.tags.addTags([approvedTag.id], to: [first.id])
        #expect(try await database.tags.tags(for: [first.id])[first.id]?.filter { $0.name.namespace == "status" }.map(\.name.rawValue) == ["status:approved"])
        do {
            _ = try await database.tags.createTag(named: TagName("status:unreviewed"))
            Issue.record("Expected unsupported controlled tag value to fail")
        } catch {
            #expect(error as? DomainValidationError == .invalidTagName)
        }
    }

    @Test("Hair Solutions template is additive and creates only declared initial vocabulary")
    func hairSolutionsTemplateApplication() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let preview = try await database.previewHairSolutionsLibraryTemplate()
        #expect(preview.folderPathsToCreate.contains("06_web/home/hero"))
        #expect(preview.tagNamesToCreate.contains { $0.rawValue == "status:review" })
        #expect(preview.onFirstUseFolderPaths.contains("04_lifestyle/active"))
        let first = try await database.applyHairSolutionsLibraryTemplate()
        #expect(!first.createdFolderIDs.isEmpty)
        #expect(!first.createdTagIDs.isEmpty)
        let tree = try await database.folders.treeSnapshot()
        #expect(tree.folders.contains { $0.name.rawValue == "00_inbox" })
        #expect(tree.folders.contains { $0.name.rawValue == "hero" })
        #expect(!tree.folders.contains { $0.name.rawValue == "active" })
        #expect(try await database.tags.tags().contains { $0.name.rawValue == "status:review" })
        #expect(try await database.tags.tags().contains { $0.name.rawValue == "channel:instagram" })

        let second = try await database.applyHairSolutionsLibraryTemplate()
        #expect(second.createdFolderIDs.isEmpty)
        #expect(second.createdTagIDs.isEmpty)
        let appliedPreview = try await database.previewHairSolutionsLibraryTemplate()
        #expect(appliedPreview.folderPathsToCreate.isEmpty)
        #expect(appliedPreview.tagNamesToCreate.isEmpty)

        let receipt = AssetExportReceipt(
            manifestSHA256: String(repeating: "a", count: 64),
            assetIDs: [AssetID()]
        )
        try await database.exports.record(receipt)
        let persistedReceipt = try #require(try await database.exports.receipts().first)
        #expect(persistedReceipt.id == receipt.id)
        #expect(persistedReceipt.manifestSHA256 == receipt.manifestSHA256)
        #expect(persistedReceipt.assetIDs == receipt.assetIDs)

        let backup = BackupManifest(manifestSHA256: String(repeating: "b", count: 64))
        try await database.backups.record(backup)
        try await database.backups.recordRestoreDrill(manifestID: backup.id, result: "passed")
        let persistedBackup = try #require(try await database.backups.manifests().first)
        #expect(persistedBackup.id == backup.id)
        #expect(persistedBackup.manifestSHA256 == backup.manifestSHA256)
        #expect(persistedBackup.lastRestoreDrillResult == "passed")
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

    @Test("Cloud migration state is additive, durable, and leaves local assets intact")
    func cloudMigrationSpine() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)

        let manifest = try await database.cloud.captureMigrationManifest(at: Date(timeIntervalSince1970: 100))
        #expect(manifest.count == 1)
        #expect(manifest[0].assetID == asset.id)
        #expect(manifest[0].storageKey == asset.storageKey)
        #expect(manifest[0].sha256 == nil)

        let digest = String(repeating: "a", count: 64)
        try await database.cloud.recordHash(digest, for: asset.id)
        let blob = CloudBlob(
            sha256: digest,
            byteSize: asset.fileSize,
            mediaType: "image/jpeg",
            originalExtension: "jpg",
            remoteBlobID: digest,
            verificationState: .verified,
            verifiedAt: Date(timeIntervalSince1970: 200)
        )
        try await database.cloud.upsertBlob(blob, at: Date(timeIntervalSince1970: 200))
        try await database.cloud.associate(AssetCloudState(assetID: asset.id, blobSHA256: digest))

        let byteDuplicate = try makeAsset(parentFolderID: database.inboxID, filename: "duplicate.jpg")
        try await database.insertAsset(byteDuplicate)
        try await database.cloud.associate(AssetCloudState(assetID: byteDuplicate.id, blobSHA256: digest))

        #expect(try await database.cloud.migrationManifest().first?.sha256 == digest)
        #expect(try await database.cloud.blob(sha256: digest)?.verificationState == .verified)
        #expect(try await database.cloud.cloudState(for: asset.id)?.materializationState == .localVerified)
        #expect(try await database.assets.asset(id: asset.id)?.storageKey == asset.storageKey)
        #expect(try await database.cloud.duplicateCandidates() == [DuplicateCandidate(sha256: digest, assetIDs: [asset.id, byteDuplicate.id].sorted { $0.description < $1.description })])

        let outbox = SyncOutboxEntry(
            idempotencyKey: "fixture-mutation-0001",
            operation: "update_rating",
            payload: Data("{}".utf8),
            nextAttemptAt: Date(timeIntervalSince1970: 0)
        )
        try await database.cloud.appendOutbox(outbox)
        #expect(try await database.cloud.dueOutboxEntries(at: Date(timeIntervalSince1970: 1)).map(\.id) == [outbox.id])
        try await database.cloud.recordConflict(SyncConflict(
            entityType: "asset", entityID: asset.id.description,
            localPayload: Data("local".utf8), remotePayload: Data("remote".utf8)
        ))
        let status = try await database.cloud.status()
        #expect(status.pendingOutboxCount == 1)
        #expect(status.unresolvedConflictCount == 1)
    }

    @Test("Remote tag and saved-search records retain IDs, membership, and revisions")
    func remoteOrganizationRecords() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let tag = Tag(id: TagID(), name: try TagName("status:review"))
        let search = SavedSearch(
            id: SavedSearchID(),
            name: try SavedSearchName("Needs Review"),
            filter: AssetFilter(tagIDs: [tag.id]),
            sort: AssetSort(key: .modifiedAt, direction: .descending)
        )

        try await database.cloud.applyRemoteRecords([
            .tag(tag: tag, assetIDs: [asset.id], revision: 7),
            .savedSearch(search: search, revision: 11)
        ])

        #expect(try await database.tags.tags().map(\.id).contains(tag.id))
        #expect(try await database.tags.tags(for: [asset.id])[asset.id]?.map(\.id) == [tag.id])
        #expect(try await database.savedSearches.savedSearches().first?.id == search.id)
        #expect(try await database.cloud.remoteRevision(entityType: "tag", entityID: tag.id.description) == 7)
        #expect(try await database.cloud.remoteRevision(entityType: "saved_search", entityID: search.id.description) == 11)
    }

    @Test("Remote Trash receipt keeps originals untouched and restores the logical recovery state")
    func remoteTrashRecord() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let folder = try await database.folders.createFolder(named: FolderName("Keep"), in: nil)
        let asset = try makeAsset(parentFolderID: folder.id)
        try await database.insertAsset(asset)
        let blob = CloudBlob(sha256: String(repeating: "f", count: 64), byteSize: asset.fileSize, mediaType: "image/jpeg", originalExtension: "jpg", remoteBlobID: String(repeating: "f", count: 64), verificationState: .verified)
        let album = try await database.albums.createAlbum(named: "Trash receipt album")
        try await database.albums.addAssets([asset.id], to: album.id)
        let tag = try await database.tags.createTag(named: TagName("status:review"))
        try await database.tags.addTags([tag.id], to: [asset.id])
        let receipt = AssetTrashReceipt(assetID: asset.id, priorFolderID: folder.id, albumIDs: [album.id], tagIDs: [tag.id], trashedAt: .now, scheduledPurgeAt: .now.addingTimeInterval(86_400))
        try await database.cloud.applyRemoteRecords([.asset(asset: asset, blob: blob, trashReceipt: receipt, revision: 4)])
        #expect(try await database.assets.asset(id: asset.id)?.parentFolderID == database.inboxID)
        #expect(try await database.assets.trashedAssets(sortedBy: .defaultSort).records.map(\.id) == [asset.id])
        #expect(try await database.assets.trashReceipts(for: [asset.id]).first?.priorFolderID == folder.id)
        #expect(try await database.assets.count(matching: AssetQuery(scope: .album(album.id))) == 0)
        #expect((try await database.tags.tags(for: [asset.id]))[asset.id]?.isEmpty ?? true)
    }

    @Test("Remote organization tombstones remove local entities but retain their revisions")
    func remoteOrganizationTombstones() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let album = try await database.albums.createAlbum(named: "Retire")
        let tag = try await database.tags.createTag(named: TagName("status:review"))
        let search = SavedSearch(name: try SavedSearchName("Retire"), filter: .init())
        try await database.savedSearches.save(search)

        try await database.cloud.applyRemoteDeletion(entityType: "album", entityID: album.id.description, revision: 4)
        try await database.cloud.applyRemoteDeletion(entityType: "tag", entityID: tag.id.description, revision: 5)
        try await database.cloud.applyRemoteDeletion(entityType: "saved_search", entityID: search.id.description, revision: 6)

        #expect(try await database.albums.albums().isEmpty)
        #expect(try await database.tags.tags().isEmpty)
        #expect(try await database.savedSearches.savedSearches().isEmpty)
        #expect(try await database.cloud.remoteRevision(entityType: "album", entityID: album.id.description) == 4)
        #expect(try await database.cloud.remoteRevision(entityType: "tag", entityID: tag.id.description) == 5)
        #expect(try await database.cloud.remoteRevision(entityType: "saved_search", entityID: search.id.description) == 6)
    }

    @Test("Remote export receipts retain their immutable manifest evidence and revision")
    func remoteExportReceipt() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let receipt = AssetExportReceipt(manifestSHA256: String(repeating: "a", count: 64), assetIDs: [])
        try await database.cloud.applyRemoteRecords([.exportReceipt(receipt: receipt, revision: 8)])

        let persisted = try #require(try await database.exports.receipts().first)
        #expect(persisted.id == receipt.id)
        #expect(persisted.manifestSHA256 == receipt.manifestSHA256)
        #expect(persisted.assetIDs == receipt.assetIDs)
        #expect(try await database.cloud.remoteRevision(entityType: "export_receipt", entityID: receipt.id.description) == 8)
    }

    @Test("Remote backup manifests retain restore-drill evidence and revision")
    func remoteBackupManifest() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let manifest = BackupManifest(
            manifestSHA256: String(repeating: "b", count: 64),
            lastRestoreDrillAt: .now,
            lastRestoreDrillResult: "passed"
        )
        try await database.cloud.applyRemoteRecords([.backupManifest(manifest: manifest, revision: 9)])

        let persisted = try #require(try await database.backups.manifests().first)
        #expect(persisted.id == manifest.id)
        #expect(persisted.lastRestoreDrillResult == "passed")
        #expect(try await database.cloud.remoteRevision(entityType: "backup_manifest", entityID: manifest.id.description) == 9)
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

    @Test("Remote catalog application preserves identities and marks unknown originals remote-only")
    func remoteCatalogApplication() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = Folder(id: FolderID(), name: try FolderName("Remote"), createdAt: date, updatedAt: date, sortOrder: 1_024)
        let asset = try makeAsset(parentFolderID: folder.id, filename: "remote.jpg", importedAt: date)
        let blob = CloudBlob(
            sha256: String(repeating: "a", count: 64), byteSize: asset.fileSize, mediaType: "image/jpeg",
            originalExtension: "jpg", remoteBlobID: String(repeating: "a", count: 64), verificationState: .verified, verifiedAt: date
        )

        try await database.cloud.applyRemoteRecords([
            .folder(folder: folder, revision: 4),
            .asset(asset: asset, blob: blob, trashReceipt: nil, revision: 5)
        ], at: date)

        let restored = try #require(try await database.assets.asset(id: asset.id))
        #expect(restored.id == asset.id)
        #expect(restored.storageKey == asset.storageKey)
        #expect(try await database.assets.page(matching: AssetQuery(scope: .allAssets), sortedBy: .defaultSort, offset: 0, limit: 10).records.first?.originalAvailable == false)
        #expect(try await database.cloud.cloudState(for: asset.id)?.remoteRevision == 5)
        #expect(try await database.cloud.remoteRevision(entityType: "folder", entityID: folder.id.description) == 4)
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
