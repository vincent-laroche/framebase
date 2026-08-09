import FramebaseAPIClient
import Foundation
import GRDB

public enum FramebaseSyncFoundation {
    public static let initialSchemaVersion = 1
    public static let migrationIdentifier = "v1_initial_sync_state"

    public static func configure(_ configuration: inout Configuration) {
        configuration.journalMode = .wal
        configuration.label = "Framebase Sync State"
    }
}

public enum SyncStateStoreError: Error, Equatable, Sendable {
    case invalidDatabaseURL
    case corruptedOutboxRecord(String)
}

/// GRDB-backed `OutboxStore` + `SyncCursorStore`, in its own database file
/// separate from `FramebaseCatalog`'s `catalog.sqlite`. Sync bookkeeping
/// (pending mutations, the change-feed cursor) is not catalog domain data, so
/// this avoids extending a shared domain contract for a capability nothing
/// consumes yet.
public final class SyncStateStore: OutboxStore, SyncCursorStore, Sendable {
    let databasePool: DatabasePool

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL, !databaseURL.hasDirectoryPath else {
            throw SyncStateStoreError.invalidDatabaseURL
        }

        var configuration = Configuration()
        FramebaseSyncFoundation.configure(&configuration)
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(pool)
        self.databasePool = pool
    }

    // MARK: - SyncCursorStore

    public func currentRevision() async throws -> Int {
        try await databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT revision FROM sync_cursor WHERE id = 1") ?? 0
        }
    }

    public func advance(to revision: Int) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE sync_cursor SET revision = ? WHERE id = 1 AND revision < ?",
                arguments: [revision, revision]
            )
        }
    }

    // MARK: - OutboxStore

    public func enqueue(_ mutation: OutboxMutation) async throws {
        let operationsJSON = try Self.encodeOperations(mutation)
        try await databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO outbox_mutations (id, actor_id, operations_json, created_at_ms, attempt_count, applied_at_ms)
                    VALUES (?, ?, ?, ?, 0, NULL)
                    """,
                arguments: [mutation.id, mutation.actorId, operationsJSON, Self.milliseconds(mutation.createdAt)]
            )
        }
    }

    public func pendingMutations() async throws -> [OutboxMutation] {
        // Ordered by `rowid`, i.e. insertion order, rather than
        // `created_at_ms`: two mutations enqueued within the same
        // millisecond would otherwise tie and fall back to sorting by `id`
        // (a random UUID), silently reordering operations that can depend on
        // each other (e.g. move-into-folder after create-folder).
        let rows = try await databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, actor_id, operations_json, created_at_ms, attempt_count
                    FROM outbox_mutations
                    WHERE applied_at_ms IS NULL
                    ORDER BY rowid
                    """
            )
        }
        return try rows.map { row in
            let id: String = row["id"]
            let operationsJSON: String = row["operations_json"]
            guard let operations = try? JSONDecoder().decode(
                [MutationOperation].self,
                from: Data(operationsJSON.utf8)
            ) else {
                throw SyncStateStoreError.corruptedOutboxRecord(id)
            }
            return OutboxMutation(
                id: id,
                actorId: row["actor_id"],
                operations: operations,
                createdAt: Self.date(row["created_at_ms"]),
                attemptCount: row["attempt_count"]
            )
        }
    }

    public func markApplied(id: String) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE outbox_mutations SET applied_at_ms = ? WHERE id = ?",
                arguments: [Self.milliseconds(Date()), id]
            )
        }
    }

    public func recordFailure(id: String) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE outbox_mutations SET attempt_count = attempt_count + 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Migration

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(FramebaseSyncFoundation.migrationIdentifier) { db in
            try db.execute(sql: Self.initialSchemaSQL)
        }
        return migrator
    }

    private static let initialSchemaSQL = """
        CREATE TABLE sync_cursor (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            revision INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO sync_cursor (id, revision) VALUES (1, 0);

        CREATE TABLE outbox_mutations (
            id TEXT PRIMARY KEY NOT NULL,
            actor_id TEXT NOT NULL,
            operations_json TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            applied_at_ms INTEGER
        );
        CREATE INDEX outbox_mutations_pending_index
            ON outbox_mutations(applied_at_ms);
        """

    private static func encodeOperations(_ mutation: OutboxMutation) throws -> String {
        let data = try JSONEncoder().encode(mutation.operations)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SyncStateStoreError.corruptedOutboxRecord(mutation.id)
        }
        return json
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
