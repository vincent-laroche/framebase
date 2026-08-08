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
}
