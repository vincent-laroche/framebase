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
            let statement = Self.queryStatement(query)
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
            let statement = Self.queryStatement(query)
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
            let statement = Self.queryStatement(query)
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
        var regions: [any DatabaseRegionConvertible] = [Table("assets"), Table("asset_trash")]
        switch query.scope {
        case .album:
            regions.append(Table("album_assets"))
        case .tag:
            regions.append(Table("asset_tags"))
        default: break
        }
        if !query.criteria.tagIDs.isEmpty {
            regions.append(Table("asset_tags"))
        }
        if !query.criteria.albumIDs.isEmpty {
            regions.append(Table("album_assets"))
        }
        if query.criteria.folderPathText != nil {
            regions.append(Table("folders"))
        }
        if query.criteria.text != nil || query.criteria.metadataText != nil {
            regions.append(Table("asset_search"))
        }
        let observation = ValueObservation.tracking(regions: regions) { db in
            let statement = Self.queryStatement(query)
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
                        var areas: Set<CatalogChange.Area> = [.assets]
                        if case .album = query.scope { areas.insert(.albums) }
                        if case .tag = query.scope { areas.insert(.tags) }
                        if !query.criteria.albumIDs.isEmpty { areas.insert(.albums) }
                        if !query.criteria.tagIDs.isEmpty { areas.insert(.tags) }
                        if query.criteria.folderPathText != nil { areas.insert(.folders) }
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
        _ = try await moveAssetsWithReceipt(assetIDs, to: folderID)
    }

    public func moveAssetsWithReceipt(_ assetIDs: Set<AssetID>, to folderID: FolderID) async throws -> AssetMoveReceipt {
        guard !assetIDs.isEmpty else { return AssetMoveReceipt(priorFolderByAssetID: [:]) }
        return try await databasePool.write { db in
            guard try Self.folderExists(folderID, in: db) else {
                throw CatalogError.folderNotFound(folderID)
            }
            let identifiers = assetIDs.map(\.description).sorted()
            let priorAssignments = try Self.folderAssignments(for: identifiers, in: db)
            guard priorAssignments.count == identifiers.count else {
                let present = Set(priorAssignments.keys.map(\.description))
                let missing = identifiers.first { !present.contains($0) }!
                throw CatalogError.assetNotFound(try Self.assetID(missing))
            }
            try Self.assign(assetIDs: identifiers, to: folderID, in: db)
            return AssetMoveReceipt(priorFolderByAssetID: priorAssignments)
        }
    }

    public func restoreAssetLocations(using receipt: AssetMoveReceipt) async throws -> AssetMoveReceipt {
        guard !receipt.priorFolderByAssetID.isEmpty else { return AssetMoveReceipt(priorFolderByAssetID: [:]) }
        return try await databasePool.write { db in
            let identifiers = receipt.priorFolderByAssetID.keys.map(\.description).sorted()
            let currentAssignments = try Self.folderAssignments(for: identifiers, in: db)
            guard currentAssignments.count == identifiers.count else {
                let present = Set(currentAssignments.keys.map(\.description))
                let missing = identifiers.first { !present.contains($0) }!
                throw CatalogError.assetNotFound(try Self.assetID(missing))
            }
            for folderID in Set(receipt.priorFolderByAssetID.values) {
                guard try Self.folderExists(folderID, in: db) else {
                    throw CatalogError.folderNotFound(folderID)
                }
                let assetIDs = receipt.priorFolderByAssetID
                    .filter { $0.value == folderID }
                    .map { $0.key.description }
                    .sorted()
                try Self.assign(assetIDs: assetIDs, to: folderID, in: db)
            }
            return AssetMoveReceipt(priorFolderByAssetID: currentAssignments)
        }
    }

    public func moveToTrash(_ assetIDs: Set<AssetID>, retentionDays: Int) async throws -> TrashReceipt {
        guard retentionDays > 0 else { throw CatalogError.invalidTrashRetentionDays(retentionDays) }
        guard !assetIDs.isEmpty else { return TrashReceipt(entries: []) }
        let orderedIDs = assetIDs.sorted { $0.description < $1.description }
        return try await databasePool.write { db in
            let now = Date()
            let expiry = Calendar.current.date(byAdding: .day, value: retentionDays, to: now) ?? now
            var entries: [TrashEntry] = []
            for assetID in orderedIDs {
                guard let priorFolderText = try String.fetchOne(
                    db, sql: "SELECT parent_folder_id FROM assets WHERE id = ?", arguments: [assetID.description]
                ), let priorFolderUUID = UUID(uuidString: priorFolderText) else {
                    throw CatalogError.assetNotFound(assetID)
                }
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM asset_trash WHERE asset_id = ?)", arguments: [assetID.description]) ?? false {
                    throw CatalogError.assetAlreadyTrashed(assetID)
                }
                entries.append(TrashEntry(assetID: assetID, priorFolderID: FolderID(rawValue: priorFolderUUID), trashedAt: now, expiresAt: expiry))
            }
            for entry in entries {
                try db.execute(
                    sql: "INSERT INTO asset_trash (asset_id, prior_folder_id, trashed_at_ms, expires_at_ms) VALUES (?, ?, ?, ?)",
                    arguments: [entry.assetID.description, entry.priorFolderID.description, CatalogDate.milliseconds(entry.trashedAt), CatalogDate.milliseconds(entry.expiresAt)]
                )
            }
            return TrashReceipt(entries: entries)
        }
    }

    public func trashEntries(assetIDs: Set<AssetID>) async throws -> [TrashEntry] {
        guard !assetIDs.isEmpty else { return [] }
        let orderedIDs = assetIDs.sorted { $0.description < $1.description }
        return try await databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT asset_id, prior_folder_id, trashed_at_ms, expires_at_ms FROM asset_trash WHERE asset_id IN (\(orderedIDs.map { _ in "?" }.joined(separator: ", "))) ORDER BY asset_id",
                arguments: StatementArguments(orderedIDs.map(\.description))
            )
            return try rows.map(Self.trashEntry)
        }
    }

    public func restoreFromTrash(using receipt: TrashReceipt) async throws {
        guard !receipt.entries.isEmpty else { return }
        try await databasePool.write { db in
            for entry in receipt.entries {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM asset_trash WHERE asset_id = ?)", arguments: [entry.assetID.description]) ?? false else {
                    throw CatalogError.assetNotFound(entry.assetID)
                }
            }
            for entry in receipt.entries {
                try db.execute(sql: "DELETE FROM asset_trash WHERE asset_id = ?", arguments: [entry.assetID.description])
            }
        }
    }

    public func restoreFromTrash(_ assetIDs: Set<AssetID>) async throws -> TrashReceipt {
        guard !assetIDs.isEmpty else { return TrashReceipt(entries: []) }
        let orderedIDs = assetIDs.sorted { $0.description < $1.description }
        return try await databasePool.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT asset_id, prior_folder_id, trashed_at_ms, expires_at_ms FROM asset_trash WHERE asset_id IN (\(orderedIDs.map { _ in "?" }.joined(separator: ", ")))",
                arguments: StatementArguments(orderedIDs.map(\.description))
            )
            guard rows.count == orderedIDs.count else {
                throw CatalogError.assetNotFound(orderedIDs.first!)
            }
            let entries = try rows.map(Self.trashEntry)
            for entry in entries {
                try db.execute(sql: "DELETE FROM asset_trash WHERE asset_id = ?", arguments: [entry.assetID.description])
            }
            return TrashReceipt(entries: entries)
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

    private static func folderAssignments(for identifiers: [String], in db: Database) throws -> [AssetID: FolderID] {
        var assignments: [AssetID: FolderID] = [:]
        for chunk in identifiers.chunked(maximumCount: 500) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, parent_folder_id FROM assets WHERE id IN (\(placeholders))",
                arguments: StatementArguments(chunk)
            )
            for row in rows {
                let assetID = try Self.assetID(row["id"] as String)
                let folderText: String = row["parent_folder_id"]
                guard let folderUUID = UUID(uuidString: folderText) else {
                    throw CatalogError.invalidPersistedIdentifier(folderText)
                }
                assignments[assetID] = FolderID(rawValue: folderUUID)
            }
        }
        return assignments
    }

    private static func assign(assetIDs: [String], to folderID: FolderID, in db: Database) throws {
        let updatedAt = CatalogDate.milliseconds(Date())
        for chunk in assetIDs.chunked(maximumCount: 500) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            var arguments: StatementArguments = [folderID.description, updatedAt]
            arguments += StatementArguments(chunk)
            try db.execute(
                sql: "UPDATE assets SET parent_folder_id = ?, updated_at_ms = ? WHERE id IN (\(placeholders))",
                arguments: arguments
            )
        }
    }

    private static func assetID(_ value: String) throws -> AssetID {
        guard let uuid = UUID(uuidString: value) else {
            throw CatalogError.invalidPersistedIdentifier(value)
        }
        return AssetID(rawValue: uuid)
    }

    private static func trashEntry(_ row: Row) throws -> TrashEntry {
        let assetID = try Self.assetID(row["asset_id"] as String)
        let folderText: String = row["prior_folder_id"]
        guard let folderUUID = UUID(uuidString: folderText) else {
            throw CatalogError.invalidPersistedIdentifier(folderText)
        }
        return TrashEntry(
            assetID: assetID,
            priorFolderID: FolderID(rawValue: folderUUID),
            trashedAt: CatalogDate.date(row["trashed_at_ms"]),
            expiresAt: CatalogDate.date(row["expires_at_ms"])
        )
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

    private static func queryStatement(_ query: AssetQuery) -> ScopeStatement {
        var statement = scopeStatement(query.scope)
        let criteria = query.criteria
        if let text = criteria.text {
            statement.append(
                """
                EXISTS (
                    SELECT 1 FROM asset_search
                    WHERE asset_search.asset_id = assets.id AND asset_search MATCH ?
                )
                """,
                argument: ftsQuery(text)
            )
        }
        if let folderPathText = criteria.folderPathText {
            statement.append(
                """
                EXISTS (
                    WITH RECURSIVE folder_paths(id, path) AS (
                        SELECT id, lower(name) FROM folders WHERE parent_folder_id IS NULL
                        UNION ALL
                        SELECT folders.id, folder_paths.path || '/' || lower(folders.name)
                        FROM folders JOIN folder_paths ON folders.parent_folder_id = folder_paths.id
                    )
                    SELECT 1 FROM folder_paths
                    WHERE folder_paths.id = assets.parent_folder_id AND folder_paths.path LIKE ?
                )
                """,
                argument: "%\(folderPathText.lowercased())%"
            )
        }
        if let metadataText = criteria.metadataText {
            statement.append(
                """
                EXISTS (
                    SELECT 1 FROM asset_search
                    WHERE asset_search.asset_id = assets.id AND asset_search MATCH ?
                )
                """,
                argument: ftsQuery(metadataText)
            )
        }
        if let capturedDateRange = criteria.capturedDateRange {
            statement.append(
                "CAST(json_extract(assets.metadata_json, '$.exif.capturedAt') AS REAL) BETWEEN ? AND ?",
                arguments: [
                    capturedDateRange.start.timeIntervalSinceReferenceDate,
                    capturedDateRange.end.timeIntervalSinceReferenceDate
                ]
            )
        }
        if let rating = criteria.rating {
            statement.append("assets.rating = ?", argument: rating.rawValue)
        }
        if let favorite = criteria.favorite {
            statement.append("assets.favorite = ?", argument: favorite)
        }
        for tagID in criteria.tagIDs.sorted(by: { $0.description < $1.description }) {
            statement.append(
                "EXISTS (SELECT 1 FROM asset_tags WHERE asset_tags.asset_id = assets.id AND asset_tags.tag_id = ?)",
                argument: tagID.description
            )
        }
        for albumID in criteria.albumIDs.sorted(by: { $0.description < $1.description }) {
            statement.append(
                "EXISTS (SELECT 1 FROM album_assets WHERE album_assets.asset_id = assets.id AND album_assets.album_id = ?)",
                argument: albumID.description
            )
        }
        return statement
    }

    private static func ftsQuery(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacing("\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
    }

    private static func scopeStatement(_ scope: AssetScope) -> ScopeStatement {
        switch scope {
        case .allAssets:
            return ScopeStatement(fromSQL: "FROM assets", predicates: ["NOT EXISTS (SELECT 1 FROM asset_trash WHERE asset_trash.asset_id = assets.id)"])
        case .inbox:
            return ScopeStatement(
                fromSQL: "FROM assets",
                predicates: ["NOT EXISTS (SELECT 1 FROM asset_trash WHERE asset_trash.asset_id = assets.id)", """
                    assets.parent_folder_id = (
                        SELECT id FROM folders WHERE system_kind = 'inbox'
                    )
                    """]
            )
        case .favorites:
            return ScopeStatement(
                fromSQL: "FROM assets",
                predicates: ["NOT EXISTS (SELECT 1 FROM asset_trash WHERE asset_trash.asset_id = assets.id)", "assets.favorite = 1"]
            )
        case let .folder(folderID):
            return ScopeStatement(
                fromSQL: "FROM assets",
                predicates: ["NOT EXISTS (SELECT 1 FROM asset_trash WHERE asset_trash.asset_id = assets.id)", "assets.parent_folder_id = ?"],
                arguments: [folderID.description]
            )
        case let .album(albumID):
            return ScopeStatement(
                fromSQL: "FROM assets JOIN album_assets ON album_assets.asset_id = assets.id",
                predicates: ["NOT EXISTS (SELECT 1 FROM asset_trash WHERE asset_trash.asset_id = assets.id)", "album_assets.album_id = ?"],
                arguments: [albumID.description]
            )
        case let .tag(tagID):
            return ScopeStatement(
                fromSQL: "FROM assets JOIN asset_tags ON asset_tags.asset_id = assets.id",
                predicates: ["NOT EXISTS (SELECT 1 FROM asset_trash WHERE asset_trash.asset_id = assets.id)", "asset_tags.tag_id = ?"],
                arguments: [tagID.description]
            )
        case .trash:
            return ScopeStatement(fromSQL: "FROM assets JOIN asset_trash ON asset_trash.asset_id = assets.id")
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
    let fromSQL: String
    private var predicates: [String]
    var arguments: StatementArguments

    init(fromSQL: String, predicates: [String] = [], arguments: StatementArguments = []) {
        self.fromSQL = fromSQL
        self.predicates = predicates
        self.arguments = arguments
    }

    var fromAndWhereSQL: String {
        guard !predicates.isEmpty else { return fromSQL }
        return "\(fromSQL) WHERE \(predicates.joined(separator: " AND "))"
    }

    mutating func append(_ predicate: String, argument: some DatabaseValueConvertible) {
        predicates.append(predicate)
        arguments += [argument]
    }

    mutating func append(_ predicate: String, arguments newArguments: StatementArguments) {
        predicates.append(predicate)
        arguments += newArguments
    }
}
