import Foundation
import FramebaseDomain
import GRDB

public enum FramebaseCatalogFoundation {
    public static let initialSchemaVersion = 1
    public static let migrationIdentifier = "v1_initial_catalog"

    public static func configure(_ configuration: inout Configuration) {
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.label = "Framebase Catalog"
    }
}

public enum CatalogError: Error, Equatable, Sendable {
    case invalidCatalogURL
    case missingCatalogIdentity
    case invalidPersistedIdentifier(String)
    case invalidPersistedValue(String)
    case invalidPage(offset: Int, limit: Int)
    case invalidAssetDisplayName
    case folderNotFound(FolderID)
    case albumNotFound(AlbumID)
    case systemFolderImmutable(FolderID)
    case invalidFolderParent(FolderID)
    case folderCycle
    case incompleteRestore
}

/// The persistence boundary for one Framebase catalog.
///
/// It owns the GRDB pool and exposes domain-facing repositories. The supplied
/// URL is always the actual `catalog.sqlite` file; library package discovery
/// and original-file storage remain outside this module.
public final class CatalogDatabase: Sendable {
    public let catalogURL: URL
    public let catalogID: CatalogID
    public let inboxID: FolderID
    public let assets: CatalogAssetRepository
    public let folders: CatalogFolderRepository
    public let albums: CatalogAlbumRepository

    let databasePool: DatabasePool

    public init(catalogURL: URL) throws {
        guard catalogURL.isFileURL, !catalogURL.hasDirectoryPath else {
            throw CatalogError.invalidCatalogURL
        }

        var configuration = Configuration()
        FramebaseCatalogFoundation.configure(&configuration)
        let pool = try DatabasePool(path: catalogURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(pool)

        let identity = try pool.read { db -> (CatalogID, FolderID) in
            guard let catalogIDText = try String.fetchOne(
                db,
                sql: "SELECT value FROM catalog_settings WHERE key = 'catalog_id'"
            ), let catalogUUID = UUID(uuidString: catalogIDText) else {
                throw CatalogError.missingCatalogIdentity
            }
            guard let inboxIDText = try String.fetchOne(
                db,
                sql: "SELECT id FROM folders WHERE system_kind = 'inbox'"
            ), let inboxUUID = UUID(uuidString: inboxIDText) else {
                throw CatalogError.missingCatalogIdentity
            }
            return (CatalogID(rawValue: catalogUUID), FolderID(rawValue: inboxUUID))
        }

        self.catalogURL = catalogURL
        self.catalogID = identity.0
        self.inboxID = identity.1
        self.databasePool = pool
        self.assets = CatalogAssetRepository(databasePool: pool)
        self.folders = CatalogFolderRepository(databasePool: pool, inboxID: identity.1)
        self.albums = CatalogAlbumRepository(databasePool: pool)
    }

    /// Inserts an already committed managed original into the catalog.
    /// `Asset.localURL` is deliberately ignored and is never persisted.
    public func insertAsset(_ asset: Asset, originalAvailable: Bool = true) async throws {
        try await insertAssets([asset], originalAvailable: originalAvailable)
    }

    /// Atomically inserts a committed import batch. A constraint failure rolls
    /// back every catalog row in the batch so the import coordinator can clean
    /// up only the newly managed files.
    public func insertAssets(_ assets: [Asset], originalAvailable: Bool = true) async throws {
        guard !assets.isEmpty else { return }
        let records = try assets.map { try AssetRecord(asset: $0, originalAvailable: originalAvailable) }
        try await databasePool.write { db in
            for record in records {
                try record.insert(db)
            }
        }
    }

    /// Creates schema-backed album fixtures/integration records. Album editing
    /// remains outside the phase-one UI, but persistence exists from migration 1.
    @discardableResult
    public func createAlbum(named name: String, at date: Date = Date()) async throws -> Album {
        let normalizedName = try CatalogValidation.normalizedName(name)
        return try await databasePool.write { db in
            let sortOrder = try CatalogSortOrder.next(
                in: db,
                table: "albums",
                predicateSQL: "1",
                arguments: []
            )
            let album = Album(
                id: AlbumID(),
                name: normalizedName,
                createdAt: date,
                updatedAt: date,
                sortOrder: sortOrder
            )
            try AlbumRecord(album: album).insert(db)
            return album
        }
    }

    public func setOriginalAvailable(_ available: Bool, for assetID: AssetID) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE assets SET original_available = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [available, CatalogDate.milliseconds(Date()), assetID.description]
            )
        }
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(FramebaseCatalogFoundation.migrationIdentifier) { db in
            try db.execute(sql: Self.initialSchemaSQL)

            let now = CatalogDate.milliseconds(Date())
            let inboxID = FolderID().description
            let catalogID = CatalogID().description
            try db.execute(
                sql: """
                    INSERT INTO folders
                        (id, name, parent_folder_id, created_at_ms, updated_at_ms, sort_order, system_kind)
                    VALUES (?, 'Inbox', NULL, ?, ?, 0, 'inbox')
                    """,
                arguments: [inboxID, now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO catalog_settings (key, value, updated_at_ms)
                    VALUES ('catalog_id', ?, ?), ('schema_version', '1', ?)
                    """,
                arguments: [catalogID, now, now]
            )
        }
        return migrator
    }

    private static let initialSchemaSQL = """
        CREATE TABLE folders (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            name TEXT NOT NULL COLLATE NOCASE
                CHECK(name = trim(name) AND length(name) BETWEEN 1 AND 255
                    AND instr(name, '/') = 0 AND instr(name, char(0)) = 0),
            parent_folder_id TEXT REFERENCES folders(id) ON DELETE RESTRICT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            system_kind TEXT
                CHECK(system_kind IS NULL OR system_kind = 'inbox')
        );

        CREATE UNIQUE INDEX folders_sibling_name_unique
            ON folders(COALESCE(parent_folder_id, ''), name COLLATE NOCASE);
        CREATE UNIQUE INDEX folders_system_kind_unique
            ON folders(system_kind) WHERE system_kind IS NOT NULL;
        CREATE INDEX folders_parent_sort_index
            ON folders(parent_folder_id, sort_order, name COLLATE NOCASE, id);

        CREATE TABLE assets (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            filename TEXT NOT NULL
                CHECK(length(filename) BETWEEN 1 AND 1024 AND instr(filename, char(0)) = 0),
            display_name TEXT NOT NULL COLLATE NOCASE
                CHECK(display_name = trim(display_name) AND length(display_name) BETWEEN 1 AND 255
                    AND instr(display_name, char(0)) = 0),
            parent_folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE RESTRICT,
            storage_key TEXT NOT NULL UNIQUE
                CHECK(length(storage_key) > 0 AND substr(storage_key, 1, 1) != '/'
                    AND instr(storage_key, '..') = 0 AND instr(storage_key, char(0)) = 0),
            media_type TEXT NOT NULL CHECK(media_type = 'stillImage'),
            width INTEGER CHECK(width IS NULL OR width > 0),
            height INTEGER CHECK(height IS NULL OR height > 0),
            file_size INTEGER NOT NULL CHECK(file_size >= 0),
            created_at_ms INTEGER NOT NULL,
            modified_at_ms INTEGER NOT NULL,
            imported_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            favorite INTEGER NOT NULL DEFAULT 0 CHECK(favorite IN (0, 1)),
            rating INTEGER NOT NULL DEFAULT 0 CHECK(rating BETWEEN 0 AND 5),
            metadata_json TEXT NOT NULL CHECK(json_valid(metadata_json)),
            original_available INTEGER NOT NULL DEFAULT 1 CHECK(original_available IN (0, 1))
        );

        CREATE INDEX assets_folder_display_name_index
            ON assets(parent_folder_id, display_name COLLATE NOCASE, id);
        CREATE INDEX assets_folder_imported_at_index
            ON assets(parent_folder_id, imported_at_ms, id);
        CREATE INDEX assets_folder_modified_at_index
            ON assets(parent_folder_id, modified_at_ms, id);
        CREATE INDEX assets_folder_created_at_index
            ON assets(parent_folder_id, created_at_ms, id);
        CREATE INDEX assets_folder_file_size_index
            ON assets(parent_folder_id, file_size, id);
        CREATE INDEX assets_folder_rating_index
            ON assets(parent_folder_id, rating, id);
        CREATE INDEX assets_display_name_index ON assets(display_name COLLATE NOCASE, id);
        CREATE INDEX assets_imported_at_index ON assets(imported_at_ms, id);
        CREATE INDEX assets_modified_at_index ON assets(modified_at_ms, id);
        CREATE INDEX assets_created_at_index ON assets(created_at_ms, id);
        CREATE INDEX assets_file_size_index ON assets(file_size, id);
        CREATE INDEX assets_rating_index ON assets(rating, id);
        CREATE INDEX assets_favorite_imported_at_index
            ON assets(favorite, imported_at_ms, id);

        CREATE TABLE albums (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            name TEXT NOT NULL COLLATE NOCASE
                CHECK(name = trim(name) AND length(name) BETWEEN 1 AND 255
                    AND instr(name, '/') = 0 AND instr(name, char(0)) = 0),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            sort_order INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX albums_name_unique ON albums(name COLLATE NOCASE);
        CREATE INDEX albums_sort_index ON albums(sort_order, name COLLATE NOCASE, id);

        CREATE TABLE album_assets (
            album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            added_at_ms INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            PRIMARY KEY(album_id, asset_id)
        );
        CREATE INDEX album_assets_album_sort_index
            ON album_assets(album_id, sort_order, asset_id);
        CREATE INDEX album_assets_asset_index ON album_assets(asset_id, album_id);

        CREATE TABLE catalog_settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        """
}

enum CatalogDate {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

enum CatalogValidation {
    static func normalizedName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 255,
              !normalized.contains("/"),
              !normalized.contains("\0") else {
            throw CatalogError.invalidAssetDisplayName
        }
        return normalized
    }
}

enum CatalogSortOrder {
    static let gap: Int64 = 1_024

    static func next(
        in db: Database,
        table: String,
        predicateSQL: String,
        arguments: StatementArguments
    ) throws -> Int64 {
        let current: Int64 = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(sort_order), 0) FROM \(table) WHERE \(predicateSQL)",
            arguments: arguments
        ) ?? 0
        guard current > Int64.max - gap else { return current + gap }

        // This is intentionally rare. Gap order is preserved for normal
        // mutations and compacted only when the integer range is exhausted.
        let rowIDs = try Int64.fetchAll(
            db,
            sql: "SELECT rowid FROM \(table) WHERE \(predicateSQL) ORDER BY sort_order, rowid",
            arguments: arguments
        )
        for (index, rowID) in rowIDs.enumerated() {
            let normalized = Int64(index + 1) * gap
            try db.execute(
                sql: "UPDATE \(table) SET sort_order = ? WHERE rowid = ?",
                arguments: [normalized, rowID]
            )
        }
        guard rowIDs.count < Int(Int64.max / gap) else {
            throw CatalogError.invalidPersistedValue("sort_order")
        }
        return Int64(rowIDs.count + 1) * gap
    }
}
