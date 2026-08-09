import Foundation
import FramebaseDomain
import GRDB

public struct CatalogAlbumRepository: AlbumRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func albums() async throws -> [Album] {
        try await databasePool.read { db in
            try AlbumRecord.fetchAll(
                db,
                sql: "SELECT * FROM albums ORDER BY sort_order, name COLLATE NOCASE, id"
            ).map { try $0.domainAlbum() }
        }
    }

    public func observeAlbums() -> AsyncThrowingStream<[Album], any Error> {
        let observation = ValueObservation.tracking { db in
            try AlbumRecord.fetchAll(
                db,
                sql: "SELECT * FROM albums ORDER BY sort_order, name COLLATE NOCASE, id"
            )
        }
        let values = observation.values(in: databasePool)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await records in values {
                        continuation.yield(try records.map { try $0.domainAlbum() })
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func createAlbum(named name: String) async throws -> Album {
        try await createAlbum(named: name, at: Date())
    }

    func createAlbum(named name: String, at date: Date) async throws -> Album {
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

    public func renameAlbum(_ albumID: AlbumID, to name: String) async throws {
        let normalizedName = try CatalogValidation.normalizedName(name)
        try await databasePool.write { db in
            guard try Self.albumExists(albumID, in: db) else {
                throw CatalogError.albumNotFound(albumID)
            }
            try db.execute(
                sql: "UPDATE albums SET name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [normalizedName, CatalogDate.milliseconds(Date()), albumID.description]
            )
        }
    }

    public func reorderAlbums(_ albumIDs: [AlbumID]) async throws {
        try await databasePool.write { db in
            let existingIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM albums ORDER BY sort_order, name COLLATE NOCASE, id"
            )
            let proposedIDs = albumIDs.map(\.description)
            guard existingIDs.count == proposedIDs.count,
                  Set(existingIDs) == Set(proposedIDs),
                  Set(proposedIDs).count == proposedIDs.count else {
                throw CatalogError.invalidAlbumOrder
            }

            let now = CatalogDate.milliseconds(Date())
            for (index, albumID) in albumIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE albums SET sort_order = ?, updated_at_ms = ? WHERE id = ?",
                    arguments: [Int64(index + 1) * CatalogSortOrder.gap, now, albumID.description]
                )
            }
        }
    }

    public func deleteAlbum(_ albumID: AlbumID) async throws -> AlbumDeletionReceipt {
        try await databasePool.write { db in
            guard let album = try Self.album(albumID, in: db) else {
                throw CatalogError.albumNotFound(albumID)
            }
            let memberships = try Self.memberships(for: albumID, in: db)
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [albumID.description])
            return AlbumDeletionReceipt(album: album, memberships: memberships)
        }
    }

    public func restoreDeletedAlbum(using receipt: AlbumDeletionReceipt) async throws {
        try await databasePool.write { db in
            try AlbumRecord(album: receipt.album).insert(db)
            for membership in receipt.memberships {
                try db.execute(
                    sql: """
                        INSERT INTO album_assets (album_id, asset_id, added_at_ms, sort_order)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        receipt.album.id.description,
                        membership.assetID.description,
                        CatalogDate.milliseconds(membership.addedAt),
                        membership.sortOrder
                    ]
                )
            }
        }
    }

    public func addAssets(_ assetIDs: Set<AssetID>, to albumID: AlbumID) async throws {
        guard !assetIDs.isEmpty else { return }
        try await databasePool.write { db in
            guard try Self.albumExists(albumID, in: db) else {
                throw CatalogError.albumNotFound(albumID)
            }
            var sortOrder = try CatalogSortOrder.next(
                in: db,
                table: "album_assets",
                predicateSQL: "album_id = ?",
                arguments: [albumID.description]
            )
            let addedAt = CatalogDate.milliseconds(Date())
            for assetID in assetIDs.sorted(by: { $0.description < $1.description }) {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO album_assets
                            (album_id, asset_id, added_at_ms, sort_order)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [albumID.description, assetID.description, addedAt, sortOrder]
                )
                if db.changesCount > 0 {
                    sortOrder += CatalogSortOrder.gap
                }
            }
        }
    }

    public func removeAssets(_ assetIDs: Set<AssetID>, from albumID: AlbumID) async throws {
        guard !assetIDs.isEmpty else { return }
        try await databasePool.write { db in
            guard try Self.albumExists(albumID, in: db) else {
                throw CatalogError.albumNotFound(albumID)
            }
            let identifiers = assetIDs.map(\.description).sorted()
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ", ")
            var arguments: StatementArguments = [albumID.description]
            arguments += StatementArguments(identifiers)
            try db.execute(
                sql: "DELETE FROM album_assets WHERE album_id = ? AND asset_id IN (\(placeholders))",
                arguments: arguments
            )
        }
    }

    private static func albumExists(_ albumID: AlbumID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM albums WHERE id = ?)",
            arguments: [albumID.description]
        ) ?? false
    }

    private static func album(_ albumID: AlbumID, in db: Database) throws -> Album? {
        try AlbumRecord.fetchOne(db, key: albumID.description)?.domainAlbum()
    }

    private static func memberships(for albumID: AlbumID, in db: Database) throws -> [AlbumAsset] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT asset_id, added_at_ms, sort_order
                FROM album_assets
                WHERE album_id = ?
                ORDER BY sort_order, asset_id
                """,
            arguments: [albumID.description]
        ).map { row in
            let identifier: String = row["asset_id"]
            guard let uuid = UUID(uuidString: identifier) else {
                throw CatalogError.invalidPersistedIdentifier(identifier)
            }
            let addedAtMilliseconds: Int64 = row["added_at_ms"]
            let sortOrder: Int64 = row["sort_order"]
            return AlbumAsset(
                albumID: albumID,
                assetID: AssetID(rawValue: uuid),
                addedAt: CatalogDate.date(addedAtMilliseconds),
                sortOrder: sortOrder
            )
        }
    }
}
