import Foundation
import FramebaseDomain
import GRDB

public struct CatalogTagRepository: TagRepository, Sendable {
    private let databasePool: DatabasePool
    init(databasePool: DatabasePool) { self.databasePool = databasePool }

    public func tags() async throws -> [Tag] {
        try await databasePool.read { db in
            try Self.fetchTags(in: db)
        }
    }

    public func observeTags() -> AsyncThrowingStream<[Tag], any Error> {
        let observation = ValueObservation.tracking { db in
            try Self.fetchTags(in: db)
        }
        let values = observation.values(in: databasePool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await tags in values { continuation.yield(tags) }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func createTag(named name: String) async throws -> Tag {
        let normalized = try CatalogValidation.normalizedName(name)
        return try await databasePool.write { db in
            let now = Date(); let tag = Tag(id: TagID(), name: normalized, createdAt: now, updatedAt: now, sortOrder: try CatalogSortOrder.next(in: db, table: "tags", predicateSQL: "1", arguments: []))
            try db.execute(sql: "INSERT INTO tags (id, name, created_at_ms, updated_at_ms, sort_order) VALUES (?, ?, ?, ?, ?)", arguments: [tag.id.description, tag.name, CatalogDate.milliseconds(now), CatalogDate.milliseconds(now), tag.sortOrder])
            return tag
        }
    }

    public func renameTag(_ tagID: TagID, to name: String) async throws {
        let normalized = try CatalogValidation.normalizedName(name)
        try await databasePool.write { db in
            guard try Self.tagExists(tagID, in: db) else {
                throw CatalogError.tagNotFound(tagID)
            }
            try db.execute(
                sql: "UPDATE tags SET name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [normalized, CatalogDate.milliseconds(Date()), tagID.description]
            )
        }
    }

    public func deleteTag(_ tagID: TagID) async throws -> TagDeletionReceipt {
        try await databasePool.write { db in
            guard let tag = try Self.fetchTags(in: db).first(where: { $0.id == tagID }) else {
                throw CatalogError.tagNotFound(tagID)
            }
            let memberships = try Row.fetchAll(db, sql: "SELECT asset_id, added_at_ms FROM asset_tags WHERE tag_id = ?", arguments: [tagID.description]).map { row in
                let assetID: String = row["asset_id"]
                guard let uuid = UUID(uuidString: assetID) else { throw CatalogError.invalidPersistedIdentifier(assetID) }
                let addedAt: Int64 = row["added_at_ms"]
                return TagAsset(tagID: tagID, assetID: AssetID(rawValue: uuid), addedAt: CatalogDate.date(addedAt))
            }
            try db.execute(
                sql: "DELETE FROM asset_tags WHERE tag_id = ?",
                arguments: [tagID.description]
            )
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tagID.description])
            return TagDeletionReceipt(tag: tag, memberships: memberships)
        }
    }

    public func restoreDeletedTag(using receipt: TagDeletionReceipt) async throws {
        try await databasePool.write { db in
            try db.execute(sql: "INSERT INTO tags (id, name, created_at_ms, updated_at_ms, sort_order) VALUES (?, ?, ?, ?, ?)", arguments: [receipt.tag.id.description, receipt.tag.name, CatalogDate.milliseconds(receipt.tag.createdAt), CatalogDate.milliseconds(receipt.tag.updatedAt), receipt.tag.sortOrder])
            for membership in receipt.memberships {
                try db.execute(sql: "INSERT INTO asset_tags (asset_id, tag_id, added_at_ms) VALUES (?, ?, ?)", arguments: [membership.assetID.description, receipt.tag.id.description, CatalogDate.milliseconds(membership.addedAt)])
            }
        }
    }

    public func addTags(_ tagIDs: Set<TagID>, to assetIDs: Set<AssetID>) async throws { try await mutate(tagIDs, assetIDs, adding: true) }
    public func removeTags(_ tagIDs: Set<TagID>, from assetIDs: Set<AssetID>) async throws { try await mutate(tagIDs, assetIDs, adding: false) }
    private func mutate(_ tagIDs: Set<TagID>, _ assetIDs: Set<AssetID>, adding: Bool) async throws {
        guard !tagIDs.isEmpty, !assetIDs.isEmpty else { return }
        try await databasePool.write { db in
            for tagID in tagIDs {
                guard try Self.tagExists(tagID, in: db) else {
                    throw CatalogError.tagNotFound(tagID)
                }
            }
            for assetID in assetIDs {
                guard try Self.assetExists(assetID, in: db) else {
                    throw CatalogError.assetNotFound(assetID)
                }
            }

            let now = CatalogDate.milliseconds(Date())
            for tagID in tagIDs {
                for assetID in assetIDs {
                    if adding {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id, added_at_ms) VALUES (?, ?, ?)",
                            arguments: [assetID.description, tagID.description, now]
                        )
                    } else {
                        try db.execute(
                            sql: "DELETE FROM asset_tags WHERE asset_id = ? AND tag_id = ?",
                            arguments: [assetID.description, tagID.description]
                        )
                    }
                }
            }
        }
    }

    private static func fetchTags(in db: Database) throws -> [Tag] {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM tags ORDER BY sort_order, name COLLATE NOCASE, id"
        ).map { try tag(from: $0) }
    }

    private static func tag(from row: Row) throws -> Tag {
        let identifier: String = row["id"]
        guard let uuid = UUID(uuidString: identifier) else {
            throw CatalogError.invalidPersistedIdentifier(identifier)
        }
        return Tag(
            id: TagID(rawValue: uuid),
            name: row["name"],
            createdAt: CatalogDate.date(row["created_at_ms"]),
            updatedAt: CatalogDate.date(row["updated_at_ms"]),
            sortOrder: row["sort_order"]
        )
    }

    private static func tagExists(_ tagID: TagID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM tags WHERE id = ?)",
            arguments: [tagID.description]
        ) ?? false
    }

    private static func assetExists(_ assetID: AssetID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM assets WHERE id = ?)",
            arguments: [assetID.description]
        ) ?? false
    }
}
