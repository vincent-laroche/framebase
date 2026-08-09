import Foundation
import FramebaseDomain
import GRDB

/// Persistence adapter for rule-backed local collections. Membership is always
/// resolved from the stored query by `AssetRepository`; this table contains no
/// asset IDs and therefore cannot alter originals or logical assignments.
public struct CatalogSmartCollectionRepository: SmartCollectionRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func smartCollections() async throws -> [SmartCollection] {
        try await databasePool.read { db in
            try Self.fetchSmartCollections(in: db)
        }
    }

    public func observeSmartCollections() -> AsyncThrowingStream<[SmartCollection], any Error> {
        let observation = ValueObservation.tracking { db in
            try Self.fetchSmartCollections(in: db)
        }
        let values = observation.values(in: databasePool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await smartCollections in values {
                        continuation.yield(smartCollections)
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

    public func createSmartCollection(named name: String, query: AssetQuery) async throws -> SmartCollection {
        let normalizedName = try CatalogValidation.normalizedName(name)
        let queryJSON = try Self.encode(query)
        return try await databasePool.write { db in
            let now = Date()
            let smartCollection = SmartCollection(
                id: SmartCollectionID(),
                name: normalizedName,
                query: query,
                createdAt: now,
                updatedAt: now,
                sortOrder: try CatalogSortOrder.next(
                    in: db,
                    table: "smart_collections",
                    predicateSQL: "1",
                    arguments: []
                )
            )
            try db.execute(
                sql: """
                    INSERT INTO smart_collections
                        (id, name, query_json, created_at_ms, updated_at_ms, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    smartCollection.id.description,
                    smartCollection.name,
                    queryJSON,
                    CatalogDate.milliseconds(now),
                    CatalogDate.milliseconds(now),
                    smartCollection.sortOrder,
                ]
            )
            return smartCollection
        }
    }

    public func renameSmartCollection(_ smartCollectionID: SmartCollectionID, to name: String) async throws {
        let normalizedName = try CatalogValidation.normalizedName(name)
        try await databasePool.write { db in
            guard try Self.exists(smartCollectionID, in: db) else {
                throw CatalogError.smartCollectionNotFound(smartCollectionID)
            }
            try db.execute(
                sql: "UPDATE smart_collections SET name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [normalizedName, CatalogDate.milliseconds(Date()), smartCollectionID.description]
            )
        }
    }

    public func deleteSmartCollection(_ smartCollectionID: SmartCollectionID) async throws {
        try await databasePool.write { db in
            guard try Self.exists(smartCollectionID, in: db) else {
                throw CatalogError.smartCollectionNotFound(smartCollectionID)
            }
            try db.execute(sql: "DELETE FROM smart_collections WHERE id = ?", arguments: [smartCollectionID.description])
        }
    }

    private static func fetchSmartCollections(in db: Database) throws -> [SmartCollection] {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM smart_collections ORDER BY sort_order, name COLLATE NOCASE, id"
        ).map { row in
            let identifier: String = row["id"]
            guard let uuid = UUID(uuidString: identifier) else {
                throw CatalogError.invalidPersistedIdentifier(identifier)
            }
            let queryJSON: String = row["query_json"]
            return SmartCollection(
                id: SmartCollectionID(rawValue: uuid),
                name: row["name"],
                query: try decode(queryJSON),
                createdAt: CatalogDate.date(row["created_at_ms"]),
                updatedAt: CatalogDate.date(row["updated_at_ms"]),
                sortOrder: row["sort_order"]
            )
        }
    }

    private static func exists(_ smartCollectionID: SmartCollectionID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM smart_collections WHERE id = ?)",
            arguments: [smartCollectionID.description]
        ) ?? false
    }

    private static func encode(_ query: AssetQuery) throws -> String {
        let data = try JSONEncoder().encode(query)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CatalogError.invalidPersistedValue("smart_collection_query")
        }
        return value
    }

    private static func decode(_ value: String) throws -> AssetQuery {
        do {
            return try JSONDecoder().decode(AssetQuery.self, from: Data(value.utf8))
        } catch {
            throw CatalogError.invalidPersistedValue("smart_collection_query")
        }
    }
}
