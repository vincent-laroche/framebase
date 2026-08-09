import Foundation
import FramebaseDomain
import GRDB

public struct CatalogSavedSearchRepository: SavedSearchRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func savedSearches() async throws -> [SavedSearch] {
        try await databasePool.read { db in
            try Self.fetchSavedSearches(in: db)
        }
    }

    public func observeSavedSearches() -> AsyncThrowingStream<[SavedSearch], any Error> {
        let observation = ValueObservation.tracking { db in
            try Self.fetchSavedSearches(in: db)
        }
        let values = observation.values(in: databasePool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await savedSearches in values {
                        continuation.yield(savedSearches)
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

    public func createSavedSearch(named name: String, query: AssetQuery) async throws -> SavedSearch {
        let normalizedName = try CatalogValidation.normalizedName(name)
        let queryJSON = try Self.encode(query)
        return try await databasePool.write { db in
            let now = Date()
            let savedSearch = SavedSearch(
                id: SavedSearchID(),
                name: normalizedName,
                query: query,
                createdAt: now,
                updatedAt: now,
                sortOrder: try CatalogSortOrder.next(
                    in: db,
                    table: "saved_searches",
                    predicateSQL: "1",
                    arguments: []
                )
            )
            try db.execute(
                sql: """
                    INSERT INTO saved_searches
                        (id, name, query_json, created_at_ms, updated_at_ms, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    savedSearch.id.description,
                    savedSearch.name,
                    queryJSON,
                    CatalogDate.milliseconds(now),
                    CatalogDate.milliseconds(now),
                    savedSearch.sortOrder
                ]
            )
            return savedSearch
        }
    }

    public func renameSavedSearch(_ savedSearchID: SavedSearchID, to name: String) async throws {
        let normalizedName = try CatalogValidation.normalizedName(name)
        try await databasePool.write { db in
            guard try Self.exists(savedSearchID, in: db) else {
                throw CatalogError.savedSearchNotFound(savedSearchID)
            }
            try db.execute(
                sql: "UPDATE saved_searches SET name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [normalizedName, CatalogDate.milliseconds(Date()), savedSearchID.description]
            )
        }
    }

    public func deleteSavedSearch(_ savedSearchID: SavedSearchID) async throws {
        try await databasePool.write { db in
            guard try Self.exists(savedSearchID, in: db) else {
                throw CatalogError.savedSearchNotFound(savedSearchID)
            }
            try db.execute(sql: "DELETE FROM saved_searches WHERE id = ?", arguments: [savedSearchID.description])
        }
    }

    private static func fetchSavedSearches(in db: Database) throws -> [SavedSearch] {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM saved_searches ORDER BY sort_order, name COLLATE NOCASE, id"
        ).map { row in
            let identifier: String = row["id"]
            guard let uuid = UUID(uuidString: identifier) else {
                throw CatalogError.invalidPersistedIdentifier(identifier)
            }
            let queryJSON: String = row["query_json"]
            return SavedSearch(
                id: SavedSearchID(rawValue: uuid),
                name: row["name"],
                query: try decode(queryJSON),
                createdAt: CatalogDate.date(row["created_at_ms"]),
                updatedAt: CatalogDate.date(row["updated_at_ms"]),
                sortOrder: row["sort_order"]
            )
        }
    }

    private static func exists(_ savedSearchID: SavedSearchID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM saved_searches WHERE id = ?)",
            arguments: [savedSearchID.description]
        ) ?? false
    }

    private static func encode(_ query: AssetQuery) throws -> String {
        let data = try JSONEncoder().encode(query)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CatalogError.invalidPersistedValue("saved_search_query")
        }
        return value
    }

    private static func decode(_ value: String) throws -> AssetQuery {
        do {
            return try JSONDecoder().decode(AssetQuery.self, from: Data(value.utf8))
        } catch {
            throw CatalogError.invalidPersistedValue("saved_search_query")
        }
    }
}
