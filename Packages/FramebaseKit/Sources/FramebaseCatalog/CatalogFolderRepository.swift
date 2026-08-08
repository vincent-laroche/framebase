import Foundation
import FramebaseDomain
import GRDB

public struct CatalogFolderRepository: FolderRepository, Sendable {
    private let databasePool: DatabasePool
    public let inboxID: FolderID

    init(databasePool: DatabasePool, inboxID: FolderID) {
        self.databasePool = databasePool
        self.inboxID = inboxID
    }

    public func treeSnapshot() async throws -> FolderTreeSnapshot {
        try await databasePool.read { db in
            try Self.fetchSnapshot(in: db, inboxID: inboxID)
        }
    }

    public func observeTree() -> AsyncThrowingStream<FolderTreeSnapshot, any Error> {
        let observation = ValueObservation.tracking { db in
            try FolderRecord.fetchAll(
                db,
                sql: "SELECT * FROM folders ORDER BY sort_order, name COLLATE NOCASE, id"
            )
        }
        let values = observation.values(in: databasePool)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await records in values {
                        continuation.yield(try Self.snapshot(from: records, inboxID: inboxID))
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

    public func createFolder(named name: FolderName, in parentFolderID: FolderID?) async throws -> Folder {
        try await databasePool.write { db in
            if let parentFolderID {
                try Self.validateMutableParent(parentFolderID, in: db)
            }
            let predicate: String
            let arguments: StatementArguments
            if let parentFolderID {
                predicate = "parent_folder_id = ?"
                arguments = [parentFolderID.description]
            } else {
                predicate = "parent_folder_id IS NULL"
                arguments = []
            }
            let now = Date()
            let folder = Folder(
                id: FolderID(),
                name: name,
                parentFolderID: parentFolderID,
                createdAt: now,
                updatedAt: now,
                sortOrder: try CatalogSortOrder.next(
                    in: db,
                    table: "folders",
                    predicateSQL: predicate,
                    arguments: arguments
                )
            )
            try FolderRecord(folder: folder).insert(db)
            return folder
        }
    }

    public func renameFolder(_ folderID: FolderID, to name: FolderName) async throws {
        try await databasePool.write { db in
            try Self.validateMutableFolder(folderID, in: db)
            try db.execute(
                sql: "UPDATE folders SET name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [name.rawValue, CatalogDate.milliseconds(Date()), folderID.description]
            )
        }
    }

    public func reparentFolder(_ folderID: FolderID, to parentFolderID: FolderID?) async throws {
        try await databasePool.write { db in
            try Self.validateMutableFolder(folderID, in: db)
            if let parentFolderID {
                guard parentFolderID != folderID else { throw CatalogError.folderCycle }
                try Self.validateMutableParent(parentFolderID, in: db)
                if try Self.isDescendant(parentFolderID, of: folderID, in: db) {
                    throw CatalogError.folderCycle
                }
            }

            let currentParent: String? = try String.fetchOne(
                db,
                sql: "SELECT parent_folder_id FROM folders WHERE id = ?",
                arguments: [folderID.description]
            )
            if currentParent == parentFolderID?.description { return }

            let predicate: String
            let arguments: StatementArguments
            if let parentFolderID {
                predicate = "parent_folder_id = ?"
                arguments = [parentFolderID.description]
            } else {
                predicate = "parent_folder_id IS NULL"
                arguments = []
            }
            let sortOrder = try CatalogSortOrder.next(
                in: db,
                table: "folders",
                predicateSQL: predicate,
                arguments: arguments
            )
            try db.execute(
                sql: """
                    UPDATE folders
                    SET parent_folder_id = ?, sort_order = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    parentFolderID?.description,
                    sortOrder,
                    CatalogDate.milliseconds(Date()),
                    folderID.description,
                ]
            )
        }
    }

    public func deletePreservingAssets(_ folderID: FolderID) async throws -> FolderDeletionReceipt {
        try await databasePool.write { db in
            try Self.validateMutableFolder(folderID, in: db)

            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH RECURSIVE subtree(id, depth) AS (
                        SELECT id, 0 FROM folders WHERE id = ?
                        UNION ALL
                        SELECT folders.id, subtree.depth + 1
                        FROM folders JOIN subtree ON folders.parent_folder_id = subtree.id
                    )
                    SELECT folders.*, subtree.depth
                    FROM folders JOIN subtree ON folders.id = subtree.id
                    ORDER BY subtree.depth ASC, folders.sort_order, folders.id
                    """,
                arguments: [folderID.description]
            )
            guard !rows.isEmpty else { throw CatalogError.folderNotFound(folderID) }

            let deletedFolders = try rows.map { try FolderRecord(row: $0).domainFolder() }
            let depthByID: [String: Int] = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row[FolderRecord.Columns.id] as String, row["depth"] as Int)
            })
            let identifiers = deletedFolders.map { $0.id.description }
            let placeholders = identifiers.map { _ in "?" }.joined(separator: ", ")
            let assignmentRows = try Row.fetchAll(
                db,
                sql: "SELECT id, parent_folder_id FROM assets WHERE parent_folder_id IN (\(placeholders))",
                arguments: StatementArguments(identifiers)
            )
            let priorAssignments = try Dictionary(uniqueKeysWithValues: assignmentRows.map { row in
                let assetText: String = row["id"]
                let folderText: String = row["parent_folder_id"]
                guard let assetUUID = UUID(uuidString: assetText), let folderUUID = UUID(uuidString: folderText) else {
                    throw CatalogError.invalidPersistedIdentifier(assetText)
                }
                return (AssetID(rawValue: assetUUID), FolderID(rawValue: folderUUID))
            })

            var moveArguments: StatementArguments = [inboxID.description, CatalogDate.milliseconds(Date())]
            moveArguments += StatementArguments(identifiers)
            try db.execute(
                sql: """
                    UPDATE assets SET parent_folder_id = ?, updated_at_ms = ?
                    WHERE parent_folder_id IN (\(placeholders))
                    """,
                arguments: moveArguments
            )

            for id in identifiers.sorted(by: { depthByID[$0, default: 0] > depthByID[$1, default: 0] }) {
                try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
            }
            return FolderDeletionReceipt(
                deletedFolders: deletedFolders,
                priorAssetAssignments: priorAssignments
            )
        }
    }

    public func restoreDeletedFolder(using receipt: FolderDeletionReceipt) async throws {
        guard !receipt.deletedFolders.isEmpty else { return }
        try await databasePool.write { db in
            var pending = receipt.deletedFolders
            let deletedIDs = Set(pending.map(\.id))
            var restoredIDs = Set<FolderID>()

            while !pending.isEmpty {
                let ready = pending.filter { folder in
                    guard let parent = folder.parentFolderID else { return true }
                    return !deletedIDs.contains(parent) || restoredIDs.contains(parent)
                }
                guard !ready.isEmpty else { throw CatalogError.incompleteRestore }
                for folder in ready.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    guard folder.systemKind == nil else {
                        throw CatalogError.systemFolderImmutable(folder.id)
                    }
                    try FolderRecord(folder: folder).insert(db)
                    restoredIDs.insert(folder.id)
                }
                let readyIDs = Set(ready.map(\.id))
                pending.removeAll { readyIDs.contains($0.id) }
            }

            let timestamp = CatalogDate.milliseconds(Date())
            for (assetID, folderID) in receipt.priorAssetAssignments {
                try db.execute(
                    sql: "UPDATE assets SET parent_folder_id = ?, updated_at_ms = ? WHERE id = ?",
                    arguments: [folderID.description, timestamp, assetID.description]
                )
            }
        }
    }

    private static func fetchSnapshot(in db: Database, inboxID: FolderID) throws -> FolderTreeSnapshot {
        let records = try FolderRecord.fetchAll(
            db,
            sql: "SELECT * FROM folders ORDER BY sort_order, name COLLATE NOCASE, id"
        )
        return try snapshot(from: records, inboxID: inboxID)
    }

    private static func snapshot(from records: [FolderRecord], inboxID: FolderID) throws -> FolderTreeSnapshot {
        let folders = try records.map { try $0.domainFolder() }
        let roots = folders
            .filter { $0.parentFolderID == nil && $0.systemKind == nil }
            .map(\.id)
        var children: [FolderID: [FolderID]] = [:]
        for folder in folders where folder.systemKind == nil {
            if let parentID = folder.parentFolderID {
                children[parentID, default: []].append(folder.id)
            }
        }
        return FolderTreeSnapshot(
            folders: folders,
            roots: roots,
            childrenByParent: children,
            inboxID: inboxID
        )
    }

    private static func validateMutableFolder(_ folderID: FolderID, in db: Database) throws {
        guard let kind: String? = try Optional<String>.fetchOne(
            db,
            sql: "SELECT system_kind FROM folders WHERE id = ?",
            arguments: [folderID.description]
        ) else {
            throw CatalogError.folderNotFound(folderID)
        }
        if kind != nil { throw CatalogError.systemFolderImmutable(folderID) }
    }

    private static func validateMutableParent(_ folderID: FolderID, in db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT system_kind FROM folders WHERE id = ?",
            arguments: [folderID.description]
        ) else {
            throw CatalogError.invalidFolderParent(folderID)
        }
        let kind: String? = row["system_kind"]
        if kind != nil { throw CatalogError.invalidFolderParent(folderID) }
    }

    private static func isDescendant(_ candidateID: FolderID, of folderID: FolderID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                WITH RECURSIVE descendants(id) AS (
                    SELECT id FROM folders WHERE parent_folder_id = ?
                    UNION ALL
                    SELECT folders.id
                    FROM folders JOIN descendants ON folders.parent_folder_id = descendants.id
                )
                SELECT EXISTS(SELECT 1 FROM descendants WHERE id = ?)
                """,
            arguments: [folderID.description, candidateID.description]
        ) ?? false
    }
}
