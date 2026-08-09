import Foundation
import FramebaseDomain
import GRDB

public final class CatalogBlobRepository: BlobRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) { self.databasePool = databasePool }

    public func register(_ blob: Blob) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state, verification_etag, verified_at_ms, created_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [blob.sha256, blob.sha256, blob.byteSize, blob.mediaType, blob.originalExtension, blob.r2Key, blob.uploadState.rawValue, blob.verificationETag, blob.verifiedAt.map(CatalogDate.milliseconds), CatalogDate.milliseconds(blob.createdAt)]
            )
        }
    }

    public func blob(sha256: String) async throws -> Blob? {
        try await databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM blobs WHERE sha256 = ?", arguments: [sha256]) else { return nil }
            guard let state = BlobUploadState(rawValue: row["upload_state"] as String) else { throw CatalogError.invalidPersistedValue("upload_state") }
            return Blob(sha256: row["sha256"], byteSize: row["byte_size"], mediaType: row["media_type"], originalExtension: row["original_extension"], r2Key: row["r2_key"], uploadState: state, verificationETag: row["verification_etag"], verifiedAt: (row["verified_at_ms"] as Int64?).map(CatalogDate.date), createdAt: CatalogDate.date(row["created_at_ms"]))
        }
    }

    public func link(assetID: AssetID, toBlobSHA256 sha256: String) async throws {
        try await databasePool.write { db in
            try db.execute(sql: "INSERT INTO asset_blobs (asset_id, blob_id, linked_at_ms) VALUES (?, ?, ?)", arguments: [assetID.description, sha256, CatalogDate.milliseconds(Date())])
        }
    }

    public func blobSHA256(for assetID: AssetID) async throws -> String? {
        try await databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT blob_id FROM asset_blobs WHERE asset_id = ?", arguments: [assetID.description])
        }
    }

    public func duplicateCandidates() async throws -> [DuplicateCandidate] {
        try await databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT blob_id, group_concat(asset_id, '|') AS asset_ids
                    FROM asset_blobs
                    GROUP BY blob_id
                    HAVING COUNT(*) > 1
                    ORDER BY blob_id
                    """
            )
            return try rows.map { row in
                let sha256: String = row["blob_id"]
                let assetIDs = try (row["asset_ids"] as String)
                    .split(separator: "|")
                    .map { value -> AssetID in
                        let identifier = String(value)
                        guard let uuid = UUID(uuidString: identifier) else {
                            throw CatalogError.invalidPersistedIdentifier(identifier)
                        }
                        return AssetID(rawValue: uuid)
                    }
                    .sorted { $0.description < $1.description }
                return DuplicateCandidate(sha256: sha256, assetIDs: assetIDs)
            }
        }
    }
}
