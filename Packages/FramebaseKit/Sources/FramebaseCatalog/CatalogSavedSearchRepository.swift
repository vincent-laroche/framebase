import Foundation
import FramebaseDomain
import GRDB

public struct CatalogSavedSearchRepository: SavedSearchRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func savedSearches() async throws -> [SavedSearch] {
        try await databasePool.read { db in try Self.fetchAll(in: db) }
    }

    public func save(_ savedSearch: SavedSearch) async throws {
        try await databasePool.write { db in
            let filter = try JSONEncoder().encode(savedSearch.filter)
            let sort = try JSONEncoder().encode(savedSearch.sort)
            guard let filterJSON = String(data: filter, encoding: .utf8),
                  let sortJSON = String(data: sort, encoding: .utf8) else {
                throw CatalogError.invalidPersistedValue("saved_search_json")
            }
            try db.execute(
                sql: """
                    INSERT INTO saved_searches (id, name, filter_json, sort_json, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, filter_json = excluded.filter_json,
                    sort_json = excluded.sort_json, updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    savedSearch.id.description,
                    savedSearch.name.rawValue,
                    filterJSON,
                    sortJSON,
                    CatalogDate.milliseconds(savedSearch.createdAt),
                    CatalogDate.milliseconds(Date())
                ]
            )
        }
    }

    public func deleteSavedSearch(_ savedSearchID: SavedSearchID) async throws {
        try await databasePool.write { db in
            try db.execute(sql: "DELETE FROM saved_searches WHERE id = ?", arguments: [savedSearchID.description])
            guard db.changesCount > 0 else { throw CatalogError.savedSearchNotFound(savedSearchID) }
        }
    }

    private static func fetchAll(in db: Database) throws -> [SavedSearch] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM saved_searches ORDER BY name COLLATE NOCASE, id")
        return try rows.map { row in
            let id: String = row["id"]
            let name: String = row["name"]
            let filterJSON: String = row["filter_json"]
            let sortJSON: String = row["sort_json"]
            guard let uuid = UUID(uuidString: id) else { throw CatalogError.invalidPersistedIdentifier(id) }
            return SavedSearch(
                id: SavedSearchID(rawValue: uuid),
                name: try SavedSearchName(name),
                filter: try JSONDecoder().decode(AssetFilter.self, from: Data(filterJSON.utf8)),
                sort: try JSONDecoder().decode(AssetSort.self, from: Data(sortJSON.utf8)),
                createdAt: CatalogDate.date(row["created_at_ms"]),
                updatedAt: CatalogDate.date(row["updated_at_ms"])
            )
        }
    }
}
