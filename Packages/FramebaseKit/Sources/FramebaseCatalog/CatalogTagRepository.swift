import Foundation
import FramebaseDomain
import GRDB

public struct CatalogTagRepository: TagRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func tags() async throws -> [Tag] {
        try await databasePool.read { db in
            try Self.fetchTags(in: db)
        }
    }

    public func observeTags() -> AsyncThrowingStream<[Tag], any Error> {
        let values = ValueObservation.tracking { db in
            try Self.fetchTags(in: db)
        }.values(in: databasePool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await tags in values { continuation.yield(tags) }
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

    public func createTag(named name: TagName) async throws -> Tag {
        try await databasePool.write { db in
            try Self.validateTemplateTag(name)
            let now = Date()
            let tag = Tag(name: name, createdAt: now, updatedAt: now)
            try db.execute(
                sql: "INSERT INTO tags (id, namespace, value, name, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [tag.id.description, name.namespace, name.value, name.rawValue, CatalogDate.milliseconds(now), CatalogDate.milliseconds(now)]
            )
            return tag
        }
    }

    public func renameTag(_ tagID: TagID, to name: TagName) async throws {
        try await databasePool.write { db in
            try Self.requireTag(tagID, in: db)
            try Self.validateTemplateTag(name)
            try db.execute(
                sql: "UPDATE tags SET namespace = ?, value = ?, name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [name.namespace, name.value, name.rawValue, CatalogDate.milliseconds(Date()), tagID.description]
            )
        }
    }

    public func deleteTag(_ tagID: TagID) async throws {
        try await databasePool.write { db in
            try Self.requireTag(tagID, in: db)
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [tagID.description])
        }
    }

    public func tags(for assetIDs: Set<AssetID>) async throws -> [AssetID: [Tag]] {
        guard !assetIDs.isEmpty else { return [:] }
        return try await databasePool.read { db in
            let ids = assetIDs.map(\.description).sorted()
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT asset_tags.asset_id AS asset_id, tags.*
                    FROM asset_tags JOIN tags ON tags.id = asset_tags.tag_id
                    WHERE asset_tags.asset_id IN (\(placeholders))
                    ORDER BY tags.namespace, tags.value, tags.id
                    """,
                arguments: StatementArguments(ids)
            )
            var result: [AssetID: [Tag]] = [:]
            for row in rows {
                let assetText: String = row["asset_id"]
                guard let assetUUID = UUID(uuidString: assetText) else {
                    throw CatalogError.invalidPersistedIdentifier(assetText)
                }
                result[AssetID(rawValue: assetUUID), default: []].append(try TagRecord(row: row).domainTag())
            }
            return result
        }
    }

    public func addTags(_ tagIDs: Set<TagID>, to assetIDs: Set<AssetID>) async throws {
        guard !tagIDs.isEmpty, !assetIDs.isEmpty else { return }
        try await databasePool.write { db in
            let tags = try tagIDs.map { tagID -> Tag in
                guard let tag = try TagRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM tags WHERE id = ?",
                    arguments: [tagID.description]
                )?.domainTag() else {
                    throw CatalogError.tagNotFound(tagID)
                }
                return tag
            }
            let singleValueNamespaces = Set(tags.compactMap { tag -> String? in
                guard let template = HairSolutionsLibraryTemplate.tagNamespace(named: tag.name.namespace),
                      !template.allowsMultipleValuesPerAsset else { return nil }
                return tag.name.namespace
            })
            for namespace in singleValueNamespaces {
                guard tags.filter({ $0.name.namespace == namespace }).count == 1 else {
                    throw DomainValidationError.invalidTagCardinality
                }
            }
            let now = CatalogDate.milliseconds(Date())
            for assetID in assetIDs {
                for namespace in singleValueNamespaces {
                    try db.execute(
                        sql: "DELETE FROM asset_tags WHERE asset_id = ? AND tag_id IN (SELECT id FROM tags WHERE namespace = ?)",
                        arguments: [assetID.description, namespace]
                    )
                }
                for tag in tags {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id, added_at_ms) VALUES (?, ?, ?)",
                        arguments: [assetID.description, tag.id.description, now]
                    )
                }
            }
        }
    }

    public func removeTags(_ tagIDs: Set<TagID>, from assetIDs: Set<AssetID>) async throws {
        guard !tagIDs.isEmpty, !assetIDs.isEmpty else { return }
        try await databasePool.write { db in
            for assetID in assetIDs {
                for tagID in tagIDs {
                    try db.execute(
                        sql: "DELETE FROM asset_tags WHERE asset_id = ? AND tag_id = ?",
                        arguments: [assetID.description, tagID.description]
                    )
                }
            }
        }
    }

    private static func fetchTags(in db: Database) throws -> [Tag] {
        try TagRecord.fetchAll(db, sql: "SELECT * FROM tags ORDER BY namespace, value, id").map { try $0.domainTag() }
    }

    private static func requireTag(_ tagID: TagID, in db: Database) throws {
        let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tags WHERE id = ?)", arguments: [tagID.description]) ?? false
        guard exists else { throw CatalogError.tagNotFound(tagID) }
    }

    private static func validateTemplateTag(_ tagName: TagName) throws {
        guard HairSolutionsLibraryTemplate.validates(tagName) else {
            throw DomainValidationError.invalidTagName
        }
    }
}

struct TagRecord: FetchableRecord, Sendable {
    let id: String
    let name: String
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    init(row: Row) {
        id = row["id"]
        name = row["name"]
        createdAtMilliseconds = row["created_at_ms"]
        updatedAtMilliseconds = row["updated_at_ms"]
    }

    func domainTag() throws -> Tag {
        guard let uuid = UUID(uuidString: id) else { throw CatalogError.invalidPersistedIdentifier(id) }
        return Tag(
            id: TagID(rawValue: uuid),
            name: try TagName(name),
            createdAt: CatalogDate.date(createdAtMilliseconds),
            updatedAt: CatalogDate.date(updatedAtMilliseconds)
        )
    }
}
