import Foundation
import FramebaseDomain
import GRDB

public enum MigrationManifestState: String, Codable, Equatable, Sendable {
    case inventoried
    case hashed
    case uploaded
    case verified
    case registered
    case failed
    case cancelled
}

public struct MigrationManifestEntry: Equatable, Sendable {
    public let assetID: AssetID
    public let storageKey: String
    public let byteSize: Int64
    public let sha256: String?
    public let remoteBlobID: String?
    public let remoteR2Key: String?
    public let remoteAssetID: String?
    public let state: MigrationManifestState
    public let retryCount: Int
    public let lastError: String?

    public init(assetID: AssetID, storageKey: String, byteSize: Int64, sha256: String?, remoteBlobID: String?, remoteR2Key: String? = nil, remoteAssetID: String?, state: MigrationManifestState, retryCount: Int, lastError: String?) {
        self.assetID = assetID
        self.storageKey = storageKey
        self.byteSize = byteSize
        self.sha256 = sha256
        self.remoteBlobID = remoteBlobID
        self.remoteR2Key = remoteR2Key
        self.remoteAssetID = remoteAssetID
        self.state = state
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

public final class MigrationManifestStore: Sendable {
    private let pool: DatabasePool

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL, !databaseURL.hasDirectoryPath else { throw MigrationManifestStoreError.invalidDatabaseURL }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.label = "Framebase Migration Manifest"
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_manifest") { db in
            try db.execute(sql: """
                CREATE TABLE migration_manifest (
                    asset_id TEXT PRIMARY KEY NOT NULL,
                    storage_key TEXT NOT NULL,
                    byte_size INTEGER NOT NULL,
                    sha256 TEXT,
                    remote_blob_id TEXT,
                    remote_asset_id TEXT,
                    state TEXT NOT NULL,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT
                )
                """)
        }
        migrator.registerMigration("v2_remote_r2_key") { db in
            try db.execute(sql: "ALTER TABLE migration_manifest ADD COLUMN remote_r2_key TEXT")
        }
        try migrator.migrate(pool)
        self.pool = pool
    }

    public func upsert(_ entry: MigrationManifestEntry) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO migration_manifest (asset_id, storage_key, byte_size, sha256, remote_blob_id, remote_r2_key, remote_asset_id, state, retry_count, last_error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET storage_key = excluded.storage_key, byte_size = excluded.byte_size,
                    sha256 = excluded.sha256, remote_blob_id = excluded.remote_blob_id, remote_r2_key = excluded.remote_r2_key, remote_asset_id = excluded.remote_asset_id,
                    state = excluded.state, retry_count = excluded.retry_count, last_error = excluded.last_error
                """, arguments: [entry.assetID.description, entry.storageKey, entry.byteSize, entry.sha256, entry.remoteBlobID, entry.remoteR2Key, entry.remoteAssetID, entry.state.rawValue, entry.retryCount, entry.lastError])
        }
    }

    public func entry(for assetID: AssetID) async throws -> MigrationManifestEntry? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM migration_manifest WHERE asset_id = ?", arguments: [assetID.description]),
                  let rawID: String = row["asset_id"], let uuid = UUID(uuidString: rawID),
                  let stateRaw: String = row["state"], let state = MigrationManifestState(rawValue: stateRaw) else { return nil }
            return MigrationManifestEntry(assetID: AssetID(rawValue: uuid), storageKey: row["storage_key"], byteSize: row["byte_size"], sha256: row["sha256"], remoteBlobID: row["remote_blob_id"], remoteR2Key: row["remote_r2_key"], remoteAssetID: row["remote_asset_id"], state: state, retryCount: row["retry_count"], lastError: row["last_error"])
        }
    }
}

public enum MigrationManifestStoreError: Error, Equatable, Sendable { case invalidDatabaseURL }
