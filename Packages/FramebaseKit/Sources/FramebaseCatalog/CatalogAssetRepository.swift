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
        if query.scope.isAlbum || !query.filter.albumIDs.isEmpty { regions.append(Table("album_assets")) }
        if !query.filter.tagIDs.isEmpty { regions.append(Table("asset_tags")) }
        if query.filter.folderPath != nil { regions.append(Table("folders")) }
        if query.filter.recognizedText != nil {
            regions.append(Table("analysis_results"))
            regions.append(Table("analysis_text_lines"))
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

    public func trashAssets(_ assetIDs: Set<AssetID>, retentionDays: Int) async throws -> [AssetTrashReceipt] {
        guard !assetIDs.isEmpty else { return [] }
        let boundedRetentionDays = min(max(retentionDays, 1), 3_650)
        return try await databasePool.write { db in
            let now = Date()
            let nowMilliseconds = CatalogDate.milliseconds(now)
            let purgeDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: boundedRetentionDays, to: now) ?? now
            let purgeMilliseconds = CatalogDate.milliseconds(purgeDate)
            guard let inboxText = try String.fetchOne(db, sql: "SELECT id FROM folders WHERE system_kind = 'inbox'"),
                  let inboxUUID = UUID(uuidString: inboxText) else {
                throw CatalogError.missingCatalogIdentity
            }
            var receipts: [AssetTrashReceipt] = []
            for assetID in assetIDs.sorted(by: { $0.description < $1.description }) {
                let alreadyTrashed = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM asset_trash WHERE asset_id = ?)",
                    arguments: [assetID.description]
                ) ?? false
                guard !alreadyTrashed else { continue }
                guard let priorFolderText = try String.fetchOne(
                    db,
                    sql: "SELECT parent_folder_id FROM assets WHERE id = ?",
                    arguments: [assetID.description]
                ), let priorFolderUUID = UUID(uuidString: priorFolderText) else {
                    continue
                }
                let albumTexts = try String.fetchAll(
                    db,
                    sql: "SELECT album_id FROM album_assets WHERE asset_id = ? ORDER BY album_id",
                    arguments: [assetID.description]
                )
                let tagTexts = try String.fetchAll(
                    db,
                    sql: "SELECT tag_id FROM asset_tags WHERE asset_id = ? ORDER BY tag_id",
                    arguments: [assetID.description]
                )
                let albumIDs = albumTexts.compactMap(UUID.init(uuidString:)).map(AlbumID.init(rawValue:))
                let tagIDs = tagTexts.compactMap(UUID.init(uuidString:)).map(TagID.init(rawValue:))
                let albumJSON = try Self.jsonArray(albumTexts)
                let tagJSON = try Self.jsonArray(tagTexts)
                try db.execute(
                    sql: """
                        INSERT INTO asset_trash
                        (asset_id, prior_folder_id, prior_album_ids_json, prior_tag_ids_json, trashed_at_ms, scheduled_purge_at_ms)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [assetID.description, priorFolderText, albumJSON, tagJSON, nowMilliseconds, purgeMilliseconds]
                )
                try db.execute(
                    sql: "UPDATE assets SET parent_folder_id = ?, updated_at_ms = ? WHERE id = ?",
                    arguments: [inboxUUID.uuidString.lowercased(), nowMilliseconds, assetID.description]
                )
                receipts.append(AssetTrashReceipt(
                    assetID: assetID,
                    priorFolderID: FolderID(rawValue: priorFolderUUID),
                    albumIDs: albumIDs,
                    tagIDs: tagIDs,
                    trashedAt: now,
                    scheduledPurgeAt: purgeDate
                ))
            }
            return receipts
        }
    }

    public func restoreAssets(_ assetIDs: Set<AssetID>) async throws {
        guard !assetIDs.isEmpty else { return }
        try await databasePool.write { db in
            guard let inboxText = try String.fetchOne(db, sql: "SELECT id FROM folders WHERE system_kind = 'inbox'") else {
                throw CatalogError.missingCatalogIdentity
            }
            let now = CatalogDate.milliseconds(Date())
            for assetID in assetIDs {
                guard let receipt = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT prior_folder_id, prior_album_ids_json, prior_tag_ids_json
                        FROM asset_trash
                        WHERE asset_id = ?
                        """,
                    arguments: [assetID.description]
                ) else { continue }
                let priorFolderText: String = receipt["prior_folder_id"]
                let priorAlbumIDs = try Self.decodeIDArray(receipt["prior_album_ids_json"] as String)
                let priorTagIDs = try Self.decodeIDArray(receipt["prior_tag_ids_json"] as String)
                let destinationExists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)",
                    arguments: [priorFolderText]
                ) ?? false
                try db.execute(
                    sql: "UPDATE assets SET parent_folder_id = ?, updated_at_ms = ? WHERE id = ?",
                    arguments: [destinationExists ? priorFolderText : inboxText, now, assetID.description]
                )
                // The receipt is authoritative. Changes to tag or album
                // membership while an asset is in Trash must not leak into a
                // restore, otherwise Trash ceases to be a recovery boundary.
                try db.execute(sql: "DELETE FROM album_assets WHERE asset_id = ?", arguments: [assetID.description])
                try db.execute(sql: "DELETE FROM asset_tags WHERE asset_id = ?", arguments: [assetID.description])
                for albumID in priorAlbumIDs {
                    try db.execute(
                        sql: """
                            INSERT INTO album_assets (album_id, asset_id, sort_order, added_at_ms)
                            SELECT ?, ?, COALESCE((SELECT MAX(sort_order) + 1_024 FROM album_assets WHERE album_id = ?), 0), ?
                            WHERE EXISTS (SELECT 1 FROM albums WHERE id = ?)
                            """,
                        arguments: [albumID, assetID.description, albumID, now, albumID]
                    )
                }
                for tagID in priorTagIDs {
                    try db.execute(
                        sql: """
                            INSERT INTO asset_tags (asset_id, tag_id, added_at_ms)
                            SELECT ?, ?, ?
                            WHERE EXISTS (SELECT 1 FROM tags WHERE id = ?)
                            """,
                        arguments: [assetID.description, tagID, now, tagID]
                    )
                }
                try db.execute(sql: "DELETE FROM asset_trash WHERE asset_id = ?", arguments: [assetID.description])
            }
        }
    }

    public func trashedAssets(sortedBy sort: AssetSort) async throws -> AssetPage {
        try await databasePool.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets JOIN asset_trash ON asset_trash.asset_id = assets.id") ?? 0
            let records = try AssetRecord.fetchAll(
                db,
                sql: "SELECT assets.* FROM assets JOIN asset_trash ON asset_trash.asset_id = assets.id \(Self.orderClause(sort))"
            )
            return AssetPage(records: try records.map { try $0.gridRecord() }, offset: 0, totalCount: count)
        }
    }

    public func trashReceipts(for assetIDs: Set<AssetID>) async throws -> [AssetTrashReceipt] {
        guard !assetIDs.isEmpty else { return [] }
        return try await databasePool.read { db in
            let identifiers = assetIDs.map(\.description).sorted()
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT asset_id, prior_folder_id, prior_album_ids_json, prior_tag_ids_json,
                           trashed_at_ms, scheduled_purge_at_ms
                    FROM asset_trash
                    WHERE asset_id IN (\(placeholders))
                    ORDER BY scheduled_purge_at_ms, asset_id
                    """,
                arguments: StatementArguments(identifiers)
            )
            return try rows.map { row in
                guard let assetUUID = UUID(uuidString: row["asset_id"] as String),
                      let folderUUID = UUID(uuidString: row["prior_folder_id"] as String) else {
                    throw CatalogError.invalidPersistedValue("asset_trash")
                }
                let albumIDs = try Self.decodeIDArray(row["prior_album_ids_json"] as String).map { value -> AlbumID in
                    guard let uuid = UUID(uuidString: value) else { throw CatalogError.invalidPersistedValue("asset_trash") }
                    return AlbumID(rawValue: uuid)
                }
                let tagIDs = try Self.decodeIDArray(row["prior_tag_ids_json"] as String).map { value -> TagID in
                    guard let uuid = UUID(uuidString: value) else { throw CatalogError.invalidPersistedValue("asset_trash") }
                    return TagID(rawValue: uuid)
                }
                return AssetTrashReceipt(
                    assetID: AssetID(rawValue: assetUUID),
                    priorFolderID: FolderID(rawValue: folderUUID),
                    albumIDs: albumIDs,
                    tagIDs: tagIDs,
                    trashedAt: CatalogDate.date(row["trashed_at_ms"] as Int64),
                    scheduledPurgeAt: CatalogDate.date(row["scheduled_purge_at_ms"] as Int64)
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

    private static func jsonArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CatalogError.invalidPersistedValue("trash_membership_json")
        }
        return json
    }

    private static func decodeIDArray(_ json: String) throws -> [String] {
        let values = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        guard values.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw CatalogError.invalidPersistedValue("trash_membership_json")
        }
        return values
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
        if query.scope != .trash {
            statement.append("NOT EXISTS(SELECT 1 FROM asset_trash WHERE asset_trash.asset_id = assets.id)")
        }

        let filter = query.filter
        if let text = filter.text, !text.isEmpty {
            let like = "%\(text.replacingOccurrences(of: "%", with: "\\%"))%"
            statement.append(
                """
                (assets.display_name LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR assets.filename LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(json_extract(assets.metadata_json, '$.exif.cameraMake'), '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(json_extract(assets.metadata_json, '$.exif.cameraModel'), '') LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR COALESCE(json_extract(assets.metadata_json, '$.exif.lensModel'), '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
                """,
                arguments: [like, like, like, like, like]
            )
        }
        if let recognizedText = filter.recognizedText, !recognizedText.isEmpty {
            let normalized = recognizedText
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let like = "%\(Self.escapedLikeLiteral(normalized))%"
            statement.append(
                """
                EXISTS(
                    SELECT 1
                    FROM analysis_results
                    JOIN analysis_text_lines ON analysis_text_lines.result_id = analysis_results.id
                    WHERE analysis_results.asset_id = assets.id
                      AND analysis_results.status = 'succeeded'
                      AND analysis_text_lines.normalized_text LIKE ? ESCAPE '\\' COLLATE NOCASE
                )
                """,
                arguments: [like]
            )
        }
        if let folderPath = filter.folderPath, !folderPath.isEmpty {
            statement.append(
                """
                EXISTS(
                    WITH RECURSIVE folder_paths(id, path) AS (
                        SELECT id, name FROM folders WHERE parent_folder_id IS NULL
                        UNION ALL
                        SELECT folders.id, folder_paths.path || '/' || folders.name
                        FROM folders JOIN folder_paths ON folders.parent_folder_id = folder_paths.id
                    )
                    SELECT 1 FROM folder_paths
                    WHERE folder_paths.id = assets.parent_folder_id AND folder_paths.path LIKE ? ESCAPE '\\' COLLATE NOCASE
                )
                """,
                arguments: ["%\(folderPath.replacingOccurrences(of: "%", with: "\\%"))%"]
            )
        }
        if !filter.tagIDs.isEmpty {
            let tags = filter.tagIDs.map(\.description).sorted()
            let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
            var arguments = StatementArguments(tags)
            arguments += [tags.count]
            statement.append(
                "assets.id IN (SELECT asset_id FROM asset_tags WHERE tag_id IN (\(placeholders)) GROUP BY asset_id HAVING COUNT(DISTINCT tag_id) = ?)",
                arguments: arguments
            )
        }
        if !filter.albumIDs.isEmpty {
            let albums = filter.albumIDs.map(\.description).sorted()
            let placeholders = albums.map { _ in "?" }.joined(separator: ", ")
            var arguments = StatementArguments(albums)
            arguments += [albums.count]
            statement.append(
                "assets.id IN (SELECT asset_id FROM album_assets WHERE album_id IN (\(placeholders)) GROUP BY asset_id HAVING COUNT(DISTINCT album_id) = ?)",
                arguments: arguments
            )
        }
        if let dateRange = filter.dateRange {
            statement.append(
                "assets.created_at_ms BETWEEN ? AND ?",
                arguments: [CatalogDate.milliseconds(dateRange.lowerBound), CatalogDate.milliseconds(dateRange.upperBound)]
            )
        }
        if let rating = filter.rating { statement.append("assets.rating = ?", arguments: [rating.rawValue]) }
        if let favorite = filter.favorite { statement.append("assets.favorite = ?", arguments: [favorite]) }
        return statement
    }

    private static func escapedLikeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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
        case .trash:
            return ScopeStatement(
                fromAndWhereSQL: "FROM assets JOIN asset_trash ON asset_trash.asset_id = assets.id",
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
    private(set) var fromAndWhereSQL: String
    private(set) var arguments: StatementArguments

    mutating func append(_ predicate: String, arguments newArguments: StatementArguments = []) {
        fromAndWhereSQL += fromAndWhereSQL.localizedCaseInsensitiveContains("WHERE") ? " AND " : " WHERE "
        fromAndWhereSQL += predicate
        arguments += newArguments
    }
}

private extension AssetScope {
    var isAlbum: Bool {
        if case .album = self { return true }
        return false
    }
}
