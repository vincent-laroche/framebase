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

    public func albums(containing assetIDs: Set<AssetID>) async throws -> [AssetID: [Album]] {
        guard !assetIDs.isEmpty else { return [:] }
        let identifiers = assetIDs.map(\.description).sorted()
        let placeholders = identifiers.map { _ in "?" }.joined(separator: ", ")

        return try await databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT album_assets.asset_id, albums.*
                    FROM album_assets
                    JOIN albums ON albums.id = album_assets.album_id
                    WHERE album_assets.asset_id IN (\(placeholders))
                    ORDER BY album_assets.asset_id, albums.sort_order, albums.name COLLATE NOCASE, albums.id
                    """,
                arguments: StatementArguments(identifiers)
            )

            var result: [AssetID: [Album]] = [:]
            for row in rows {
                let identifier: String = row["asset_id"]
                guard let uuid = UUID(uuidString: identifier) else {
                    throw CatalogError.invalidPersistedIdentifier(identifier)
                }
                let assetID = AssetID(rawValue: uuid)
                result[assetID, default: []].append(try AlbumRecord(row: row).domainAlbum())
            }
            return result
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

    public func createAlbum(named name: String) async throws -> Album {
        let normalized = try CatalogValidation.normalizedName(name)
        return try await databasePool.write { db in
            let now = Date()
            let album = Album(
                id: AlbumID(),
                name: normalized,
                createdAt: now,
                updatedAt: now,
                sortOrder: try CatalogSortOrder.next(in: db, table: "albums", predicateSQL: "1", arguments: [])
            )
            try AlbumRecord(album: album).insert(db)
            return album
        }
    }

    public func renameAlbum(_ albumID: AlbumID, to name: String) async throws {
        let normalized = try CatalogValidation.normalizedName(name)
        try await databasePool.write { db in
            guard try Self.albumExists(albumID, in: db) else { throw CatalogError.albumNotFound(albumID) }
            try db.execute(
                sql: "UPDATE albums SET name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [normalized, CatalogDate.milliseconds(Date()), albumID.description]
            )
        }
    }

    public func reorderAlbum(_ albumID: AlbumID, after predecessorID: AlbumID?) async throws {
        try await databasePool.write { db in
            guard try Self.albumExists(albumID, in: db) else { throw CatalogError.albumNotFound(albumID) }
            if let predecessorID {
                guard predecessorID != albumID, try Self.albumExists(predecessorID, in: db) else {
                    throw CatalogError.albumNotFound(predecessorID)
                }
            }
            var ids = try String.fetchAll(db, sql: "SELECT id FROM albums ORDER BY sort_order, name COLLATE NOCASE, id")
            ids.removeAll { $0 == albumID.description }
            let insertionIndex: Int
            if let predecessorID, let predecessorIndex = ids.firstIndex(of: predecessorID.description) {
                insertionIndex = predecessorIndex + 1
            } else {
                insertionIndex = 0
            }
            ids.insert(albumID.description, at: insertionIndex)
            let now = CatalogDate.milliseconds(Date())
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE albums SET sort_order = ?, updated_at_ms = ? WHERE id = ?",
                    arguments: [Int64(index + 1) * CatalogSortOrder.gap, now, id]
                )
            }
        }
    }

    public func deleteAlbum(_ albumID: AlbumID) async throws {
        try await databasePool.write { db in
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [albumID.description])
            guard db.changesCount > 0 else { throw CatalogError.albumNotFound(albumID) }
        }
    }

    private static func albumExists(_ albumID: AlbumID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM albums WHERE id = ?)",
            arguments: [albumID.description]
        ) ?? false
    }
}
