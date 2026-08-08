import Foundation
import FramebaseDomain
import GRDB
import OSLog

public struct CatalogAssetRepository: AssetRepository, Sendable {
    private let databasePool: DatabasePool
    private static let maximumPageSize = 500
    private static let signposter = OSSignposter(
        subsystem: "com.vincentlaroche.framebase",
        category: "Catalog Queries"
    )

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func count(matching query: AssetQuery) async throws -> Int {
        return try await databasePool.read { db in
            let statement = Self.scopeStatement(query.scope)
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) \(statement.fromAndWhereSQL)",
                arguments: statement.arguments
            ) ?? 0
        }
    }

    public func orderedIDs(matching query: AssetQuery, sortedBy sort: AssetSort) async throws -> [AssetID] {
        let interval = Self.signposter.beginInterval("Ordered Asset IDs")
        defer { Self.signposter.endInterval("Ordered Asset IDs", interval) }
        return try await databasePool.read { db in
            let statement = Self.scopeStatement(query.scope)
            let values = try String.fetchAll(
                db,
                sql: "SELECT assets.id \(statement.fromAndWhereSQL) \(Self.orderClause(sort))",
                arguments: statement.arguments
            )
            return try values.map(Self.assetID)
        }
    }

    public func page(
        matching query: AssetQuery,
        sortedBy sort: AssetSort,
        offset: Int,
        limit: Int
    ) async throws -> AssetPage {
        guard offset >= 0, limit > 0 else {
            throw CatalogError.invalidPage(offset: offset, limit: limit)
        }
        let boundedLimit = min(limit, Self.maximumPageSize)
        let interval = Self.signposter.beginInterval("Asset Page")
        defer { Self.signposter.endInterval("Asset Page", interval) }

        return try await databasePool.read { db in
            let statement = Self.scopeStatement(query.scope)
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) \(statement.fromAndWhereSQL)",
                arguments: statement.arguments
            ) ?? 0
            var pageArguments = statement.arguments
            pageArguments += [boundedLimit, offset]
            let records = try AssetRecord.fetchAll(
                db,
                sql: """
                    SELECT assets.*
                    \(statement.fromAndWhereSQL)
                    \(Self.orderClause(sort))
                    LIMIT ? OFFSET ?
                    """,
                arguments: pageArguments
            )
            return AssetPage(
                records: try records.map { try $0.gridRecord() },
                offset: offset,
                totalCount: count
            )
        }
    }

    public func asset(id: AssetID) async throws -> Asset? {
        try await databasePool.read { db in
            try AssetRecord
                .filter(AssetRecord.Columns.id == id.description)
                .fetchOne(db)?
                .domainAsset()
        }
    }

    public func assets(ids: Set<AssetID>) async throws -> [Asset] {
        guard !ids.isEmpty else { return [] }
        return try await databasePool.read { db in
            var assets: [Asset] = []
            let identifiers = ids.map(\.description).sorted()
            for chunk in identifiers.chunked(maximumCount: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let records = try AssetRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM assets WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                assets.append(contentsOf: try records.map { try $0.domainAsset() })
            }
            return assets
        }
    }

    public func observe(matching query: AssetQuery) -> AsyncThrowingStream<CatalogChange, any Error> {
        let regions: [any DatabaseRegionConvertible] = query.scope.isAlbum
            ? [Table("assets"), Table("album_assets")]
            : [Table("assets")]
        let observation = ValueObservation.tracking(regions: regions) { db in
            let statement = Self.scopeStatement(query.scope)
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) \(statement.fromAndWhereSQL)",
                arguments: statement.arguments
            ) ?? 0
        }
        let values = observation.values(in: databasePool)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await _ in values {
                        let areas: Set<CatalogChange.Area> = query.scope.isAlbum
                            ? [.assets, .albums]
                            : [.assets]
                        continuation.yield(CatalogChange(areas: areas))
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

    public func updateDisplayName(_ displayName: String, for assetID: AssetID) async throws {
        let normalized = try CatalogValidation.normalizedName(displayName)
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE assets SET display_name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [normalized, CatalogDate.milliseconds(Date()), assetID.description]
            )
        }
    }

    public func updateRating(_ rating: AssetRating, for assetIDs: Set<AssetID>) async throws {
        try await updateAssets(assetIDs, assignmentSQL: "rating = ?", value: rating.rawValue)
    }

    public func updateFavorite(_ favorite: Bool, for assetIDs: Set<AssetID>) async throws {
        try await updateAssets(assetIDs, assignmentSQL: "favorite = ?", value: favorite)
    }

    public func moveAssets(_ assetIDs: Set<AssetID>, to folderID: FolderID) async throws {
        guard !assetIDs.isEmpty else { return }
        try await databasePool.write { db in
            guard try Self.folderExists(folderID, in: db) else {
                throw CatalogError.folderNotFound(folderID)
            }
            let identifiers = assetIDs.map(\.description).sorted()
            let updatedAt = CatalogDate.milliseconds(Date())
            for chunk in identifiers.chunked(maximumCount: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                var arguments: StatementArguments = [folderID.description, updatedAt]
                arguments += StatementArguments(chunk)
                try db.execute(
                    sql: "UPDATE assets SET parent_folder_id = ?, updated_at_ms = ? WHERE id IN (\(placeholders))",
                    arguments: arguments
                )
            }
        }
    }

    private func updateAssets<Value: DatabaseValueConvertible & Sendable>(
        _ assetIDs: Set<AssetID>,
        assignmentSQL: String,
        value: Value
    ) async throws {
        guard !assetIDs.isEmpty else { return }
        try await databasePool.write { db in
            let identifiers = assetIDs.map(\.description).sorted()
            let updatedAt = CatalogDate.milliseconds(Date())
            for chunk in identifiers.chunked(maximumCount: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                var arguments: StatementArguments = [value, updatedAt]
                arguments += StatementArguments(chunk)
                try db.execute(
                    sql: "UPDATE assets SET \(assignmentSQL), updated_at_ms = ? WHERE id IN (\(placeholders))",
                    arguments: arguments
                )
            }
        }
    }

    private static func folderExists(_ folderID: FolderID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)",
            arguments: [folderID.description]
        ) ?? false
    }

    private static func assetID(_ value: String) throws -> AssetID {
        guard let uuid = UUID(uuidString: value) else {
            throw CatalogError.invalidPersistedIdentifier(value)
        }
        return AssetID(rawValue: uuid)
    }

    private static func orderClause(_ sort: AssetSort) -> String {
        let column: String
        switch sort.key {
        case .displayName: column = "assets.display_name COLLATE NOCASE"
        case .importedAt: column = "assets.imported_at_ms"
        case .modifiedAt: column = "assets.modified_at_ms"
        case .createdAt: column = "assets.created_at_ms"
        case .fileSize: column = "assets.file_size"
        case .rating: column = "assets.rating"
        }
        let direction = sort.direction == .ascending ? "ASC" : "DESC"
        return "ORDER BY \(column) \(direction), assets.id \(direction)"
    }

    private static func scopeStatement(_ scope: AssetScope) -> ScopeStatement {
        switch scope {
        case .allAssets:
            return ScopeStatement(fromAndWhereSQL: "FROM assets", arguments: [])
        case .inbox:
            return ScopeStatement(
                fromAndWhereSQL: """
                    FROM assets
                    WHERE assets.parent_folder_id = (
                        SELECT id FROM folders WHERE system_kind = 'inbox'
                    )
                    """,
                arguments: []
            )
        case .favorites:
            return ScopeStatement(
                fromAndWhereSQL: "FROM assets WHERE assets.favorite = 1",
                arguments: []
            )
        case let .folder(folderID):
            return ScopeStatement(
                fromAndWhereSQL: "FROM assets WHERE assets.parent_folder_id = ?",
                arguments: [folderID.description]
            )
        case let .album(albumID):
            return ScopeStatement(
                fromAndWhereSQL: """
                    FROM assets
                    JOIN album_assets ON album_assets.asset_id = assets.id
                    WHERE album_assets.album_id = ?
                    """,
                arguments: [albumID.description]
            )
        }
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [ArraySlice<Element>] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map { start in
            self[start..<Swift.min(start + maximumCount, count)]
        }
    }
}

private struct ScopeStatement: Sendable {
    let fromAndWhereSQL: String
    let arguments: StatementArguments
}

private extension AssetScope {
    var isAlbum: Bool {
        if case .album = self { return true }
        return false
    }
}
