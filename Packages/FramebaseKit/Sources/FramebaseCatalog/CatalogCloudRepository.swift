import Foundation
import FramebaseDomain
import GRDB

/// The sole SQL boundary for Phase 3 cloud state. UI code talks to
/// `FramebaseSync`; neither views nor API clients manipulate these tables.
public struct CatalogCloudRepository: Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func captureMigrationManifest(at date: Date = .now) async throws -> [CloudMigrationManifestEntry] {
        let now = CatalogDate.milliseconds(date)
        try await databasePool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO migration_manifest
                        (asset_id, storage_key, byte_size, source_modified_at_ms, sha256, captured_at_ms, updated_at_ms)
                    SELECT id, storage_key, file_size, modified_at_ms, NULL, ?, ? FROM assets WHERE 1
                    ON CONFLICT(asset_id) DO NOTHING
                    """,
                arguments: [now, now]
            )
        }
        return try await migrationManifest()
    }

    public func migrationManifest() async throws -> [CloudMigrationManifestEntry] {
        try await databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT asset_id, storage_key, byte_size, source_modified_at_ms, sha256, captured_at_ms
                FROM migration_manifest ORDER BY asset_id
                """)
            return try rows.map(Self.manifestEntry)
        }
    }

    public func recordHash(_ sha256: String, for assetID: AssetID, at date: Date = .now) async throws {
        guard Self.validSHA256(sha256) else { throw CatalogError.invalidPersistedValue("sha256") }
        let milliseconds = CatalogDate.milliseconds(date)
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE migration_manifest SET sha256 = ?, updated_at_ms = ? WHERE asset_id = ?",
                arguments: [sha256, milliseconds, assetID.description]
            )
        }
    }

    public func upsertBlob(_ blob: CloudBlob, at date: Date = .now) async throws {
        guard Self.validSHA256(blob.sha256), blob.byteSize > 0 else { throw CatalogError.invalidPersistedValue("cloud_blob") }
        let milliseconds = CatalogDate.milliseconds(date)
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO cloud_blobs
                    (sha256, byte_size, media_type, original_extension, remote_blob_id, verification_state, last_error, verified_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sha256) DO UPDATE SET
                    remote_blob_id = excluded.remote_blob_id,
                    verification_state = excluded.verification_state,
                    last_error = excluded.last_error,
                    verified_at_ms = excluded.verified_at_ms,
                    updated_at_ms = excluded.updated_at_ms
                """, arguments: [
                    blob.sha256, blob.byteSize, blob.mediaType, blob.originalExtension,
                    blob.remoteBlobID, blob.verificationState.rawValue, blob.lastError,
                    blob.verifiedAt.map(CatalogDate.milliseconds), milliseconds
                ])
        }
    }

    public func blob(sha256: String) async throws -> CloudBlob? {
        try await databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cloud_blobs WHERE sha256 = ?", arguments: [sha256]) else { return nil }
            return try Self.cloudBlob(row)
        }
    }

    public func associate(_ state: AssetCloudState, at date: Date = .now) async throws {
        let milliseconds = CatalogDate.milliseconds(date)
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO asset_cloud_state (asset_id, blob_sha256, remote_revision, materialization_state, last_error, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    blob_sha256 = excluded.blob_sha256,
                    remote_revision = excluded.remote_revision,
                    materialization_state = excluded.materialization_state,
                    last_error = excluded.last_error,
                    updated_at_ms = excluded.updated_at_ms
                """, arguments: [
                    state.assetID.description, state.blobSHA256, state.remoteRevision,
                    state.materializationState.rawValue, state.lastError, milliseconds
                ])
        }
    }

    public func cloudState(for assetID: AssetID) async throws -> AssetCloudState? {
        try await databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM asset_cloud_state WHERE asset_id = ?", arguments: [assetID.description]) else { return nil }
            return try Self.assetState(row)
        }
    }

    /// Returns only exact-byte duplicate candidates whose shared blob has
    /// reached the verified state. This method deliberately makes no merge,
    /// delete, or automatic organization decision.
    public func duplicateCandidates() async throws -> [DuplicateCandidate] {
        try await databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT asset_cloud_state.blob_sha256 AS sha256, asset_cloud_state.asset_id AS asset_id
                FROM asset_cloud_state
                JOIN cloud_blobs ON cloud_blobs.sha256 = asset_cloud_state.blob_sha256
                WHERE cloud_blobs.verification_state = 'verified'
                  AND asset_cloud_state.blob_sha256 IN (
                    SELECT blob_sha256 FROM asset_cloud_state GROUP BY blob_sha256 HAVING COUNT(*) > 1
                  )
                ORDER BY asset_cloud_state.blob_sha256, asset_cloud_state.asset_id
                """)
            var grouped: [String: [AssetID]] = [:]
            for row in rows {
                let assetIDText: String = row["asset_id"]
                guard let rawValue = UUID(uuidString: assetIDText) else {
                    throw CatalogError.invalidPersistedIdentifier(assetIDText)
                }
                grouped[row["sha256"], default: []].append(AssetID(rawValue: rawValue))
            }
            return grouped.keys.sorted().map { DuplicateCandidate(sha256: $0, assetIDs: grouped[$0, default: []]) }
        }
    }

    public func remoteRevision(entityType: String, entityID: String) async throws -> Int64? {
        guard ["folder", "album", "tag", "saved_search", "export_receipt", "backup_manifest"].contains(entityType) else {
            throw CatalogError.invalidPersistedValue("remote entity type")
        }
        return try await databasePool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT remote_revision FROM remote_entity_state WHERE entity_type = ? AND entity_id = ?",
                arguments: [entityType, entityID]
            )
        }
    }

    /// Applies a remote organization tombstone before the next authoritative
    /// snapshot. The revision is retained so a later out-of-order event cannot
    /// revive a stale local entity.
    public func applyRemoteDeletion(entityType: String, entityID: String, revision: Int64, at date: Date = .now) async throws {
        guard revision > 0, let rawID = UUID(uuidString: entityID) else {
            throw CatalogError.invalidPersistedIdentifier(entityID)
        }
        let milliseconds = CatalogDate.milliseconds(date)
        try await databasePool.write { db in
            switch entityType {
            case "album":
                try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [rawID.uuidString.lowercased()])
            case "tag":
                try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [rawID.uuidString.lowercased()])
            case "saved_search":
                try db.execute(sql: "DELETE FROM saved_searches WHERE id = ?", arguments: [rawID.uuidString.lowercased()])
            default:
                throw CatalogError.invalidPersistedValue("remote deletion entity type")
            }
            try Self.saveRemoteEntityRevision(entityType, entityID: rawID.uuidString.lowercased(), revision: revision, at: milliseconds, in: db)
        }
    }

    public func appendOutbox(_ entry: SyncOutboxEntry) async throws {
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_outbox
                    (id, idempotency_key, operation, payload, state, attempt_count, next_attempt_at_ms, last_error, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(idempotency_key) DO NOTHING
                """, arguments: [
                    entry.id.uuidString.lowercased(), entry.idempotencyKey, entry.operation, entry.payload,
                    entry.state.rawValue, entry.attemptCount, CatalogDate.milliseconds(entry.nextAttemptAt), entry.lastError,
                    CatalogDate.milliseconds(entry.createdAt), CatalogDate.milliseconds(entry.updatedAt)
                ])
        }
    }

    public func dueOutboxEntries(at date: Date = .now, limit: Int = 50) async throws -> [SyncOutboxEntry] {
        let boundedLimit = min(max(limit, 1), 500)
        return try await databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM sync_outbox
                WHERE state IN ('pending', 'failed') AND next_attempt_at_ms <= ?
                ORDER BY created_at_ms, id LIMIT ?
                """, arguments: [CatalogDate.milliseconds(date), boundedLimit])
            return try rows.map(Self.outboxEntry)
        }
    }

    public func updateOutbox(
        id: UUID,
        state: SyncOutboxState,
        attemptCount: Int? = nil,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil,
        at date: Date = .now
    ) async throws {
        try await databasePool.write { db in
            try db.execute(sql: """
                UPDATE sync_outbox SET state = ?, attempt_count = COALESCE(?, attempt_count),
                    next_attempt_at_ms = COALESCE(?, next_attempt_at_ms), last_error = ?, updated_at_ms = ?
                WHERE id = ?
                """, arguments: [
                    state.rawValue, attemptCount, nextAttemptAt.map(CatalogDate.milliseconds), lastError,
                    CatalogDate.milliseconds(date), id.uuidString.lowercased()
                ])
        }
    }

    public func recordConflict(_ conflict: SyncConflict, at date: Date = .now) async throws {
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_conflicts
                    (id, entity_type, entity_id, local_payload, remote_payload, detected_at_ms, resolution, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    conflict.id.uuidString.lowercased(), conflict.entityType, conflict.entityID,
                    conflict.localPayload, conflict.remotePayload, CatalogDate.milliseconds(conflict.detectedAt),
                    conflict.resolution.rawValue, CatalogDate.milliseconds(date)
                ])
        }
    }

    public func unresolvedConflicts(limit: Int = 20) async throws -> [SyncConflict] {
        let boundedLimit = min(max(limit, 1), 200)
        return try await databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM sync_conflicts WHERE resolution = 'unresolved'
                ORDER BY detected_at_ms DESC LIMIT ?
                """, arguments: [boundedLimit])
            return try rows.map(Self.conflict)
        }
    }

    public func resolveConflict(_ id: UUID, as resolution: SyncConflictResolutionState, at date: Date = .now) async throws {
        guard resolution != .unresolved else { throw CatalogError.invalidPersistedValue("unresolved conflict resolution") }
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE sync_conflicts SET resolution = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [resolution.rawValue, CatalogDate.milliseconds(date), id.uuidString.lowercased()]
            )
        }
    }

    public func status() async throws -> CloudLibraryStatus {
        try await databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE key = 'library'") else {
                throw CatalogError.invalidPersistedValue("sync_state")
            }
            let mode = try Self.decode(CloudLibraryMode.self, row["mode"] as String)
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox WHERE state IN ('pending', 'inFlight', 'failed')") ?? 0
            let conflicts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_conflicts WHERE resolution = 'unresolved'") ?? 0
            return CloudLibraryStatus(
                mode: mode,
                deviceID: row["device_id"],
                changeCursor: row["change_cursor"],
                lastSuccessfulSyncAt: (row["last_successful_sync_at_ms"] as Int64?).map(CatalogDate.date),
                pendingOutboxCount: pending,
                unresolvedConflictCount: conflicts,
                lastError: row["last_error"]
            )
        }
    }

    public func updateStatus(
        mode: CloudLibraryMode,
        deviceID: String? = nil,
        changeCursor: Int64? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        lastError: String? = nil,
        at date: Date = .now
    ) async throws {
        try await databasePool.write { db in
            try db.execute(sql: """
                UPDATE sync_state SET mode = ?, device_id = COALESCE(?, device_id),
                    change_cursor = COALESCE(?, change_cursor), last_successful_sync_at_ms = COALESCE(?, last_successful_sync_at_ms),
                    last_error = ?, updated_at_ms = ? WHERE key = 'library'
                """, arguments: [
                    mode.rawValue, deviceID, changeCursor, lastSuccessfulSyncAt.map(CatalogDate.milliseconds),
                    lastError, CatalogDate.milliseconds(date)
                ])
        }
    }

    /// Applies dependency-ordered remote records to a local catalog. Existing
    /// managed originals stay available only when the immutable storage key is
    /// unchanged; a newly materialized remote asset is always marked remote-only.
    public func applyRemoteRecords(_ records: [RemoteCatalogRecord], at date: Date = .now) async throws {
        let milliseconds = CatalogDate.milliseconds(date)
        try await databasePool.write { db in
            for record in records {
                switch record {
                case let .folder(folder, revision):
                    try FolderRecord(folder: folder).save(db)
                    try Self.saveRemoteEntityRevision("folder", entityID: folder.id.description, revision: revision, at: milliseconds, in: db)
                case let .album(album, assetIDs, revision):
                    try AlbumRecord(album: album).save(db)
                    try db.execute(sql: "DELETE FROM album_assets WHERE album_id = ?", arguments: [album.id.description])
                    for (offset, assetID) in assetIDs.enumerated() {
                        try db.execute(sql: """
                            INSERT INTO album_assets (album_id, asset_id, added_at_ms, sort_order)
                            VALUES (?, ?, ?, ?)
                            """, arguments: [
                                album.id.description, assetID.description, milliseconds,
                                Int64(offset + 1) * CatalogSortOrder.gap
                            ])
                    }
                    try Self.saveRemoteEntityRevision("album", entityID: album.id.description, revision: revision, at: milliseconds, in: db)
                case let .asset(remoteAsset, blob, trashReceipt, revision):
                    var asset = remoteAsset
                    if trashReceipt != nil { asset.parentFolderID = try Self.inboxID(in: db) }
                    let existing = try Row.fetchOne(
                        db, sql: "SELECT storage_key, original_available FROM assets WHERE id = ?", arguments: [asset.id.description]
                    )
                    let originalAvailable = (existing?["storage_key"] as String?) == asset.storageKey.rawValue
                        ? (existing?["original_available"] as Bool? ?? false)
                        : false
                    try AssetRecord(asset: asset, originalAvailable: originalAvailable).save(db)
                    try db.execute(sql: """
                        INSERT INTO cloud_blobs
                            (sha256, byte_size, media_type, original_extension, remote_blob_id, verification_state, last_error, verified_at_ms, updated_at_ms)
                        VALUES (?, ?, ?, ?, ?, 'verified', NULL, ?, ?)
                        ON CONFLICT(sha256) DO UPDATE SET
                            remote_blob_id = excluded.remote_blob_id, verification_state = 'verified',
                            last_error = NULL, verified_at_ms = excluded.verified_at_ms, updated_at_ms = excluded.updated_at_ms
                        """, arguments: [
                            blob.sha256, blob.byteSize, blob.mediaType, blob.originalExtension, blob.remoteBlobID,
                            milliseconds, milliseconds
                        ])
                    if let trashReceipt {
                        let albums = try JSONEncoder().encode(trashReceipt.albumIDs.map(\.description))
                        let tags = try JSONEncoder().encode(trashReceipt.tagIDs.map(\.description))
                        guard let albumsJSON = String(data: albums, encoding: .utf8),
                              let tagsJSON = String(data: tags, encoding: .utf8) else {
                            throw CatalogError.invalidPersistedValue("asset_trash")
                        }
                        try db.execute(sql: """
                            INSERT INTO asset_trash
                                (asset_id, prior_folder_id, prior_album_ids_json, prior_tag_ids_json, trashed_at_ms, scheduled_purge_at_ms)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT(asset_id) DO UPDATE SET prior_folder_id = excluded.prior_folder_id,
                            prior_album_ids_json = excluded.prior_album_ids_json, prior_tag_ids_json = excluded.prior_tag_ids_json,
                            trashed_at_ms = excluded.trashed_at_ms, scheduled_purge_at_ms = excluded.scheduled_purge_at_ms
                            """,
                            arguments: [
                                asset.id.description, trashReceipt.priorFolderID.description, albumsJSON, tagsJSON,
                                CatalogDate.milliseconds(trashReceipt.trashedAt), CatalogDate.milliseconds(trashReceipt.scheduledPurgeAt)
                            ]
                        )
                        // A receipt is the only active representation of the
                        // pre-Trash organization. Do not leave the item in a
                        // live album or tag while it is in Trash.
                        try db.execute(sql: "DELETE FROM album_assets WHERE asset_id = ?", arguments: [asset.id.description])
                        try db.execute(sql: "DELETE FROM asset_tags WHERE asset_id = ?", arguments: [asset.id.description])
                    } else {
                        try db.execute(sql: "DELETE FROM asset_trash WHERE asset_id = ?", arguments: [asset.id.description])
                    }
                    try db.execute(sql: """
                        INSERT INTO asset_cloud_state (asset_id, blob_sha256, remote_revision, materialization_state, last_error, updated_at_ms)
                        VALUES (?, ?, ?, ?, NULL, ?)
                        ON CONFLICT(asset_id) DO UPDATE SET
                            blob_sha256 = excluded.blob_sha256, remote_revision = excluded.remote_revision,
                            materialization_state = excluded.materialization_state,
                            last_error = NULL, updated_at_ms = excluded.updated_at_ms
                        """, arguments: [
                            asset.id.description, blob.sha256, revision,
                            originalAvailable ? OriginalMaterializationState.localVerified.rawValue : OriginalMaterializationState.remoteOnly.rawValue,
                            milliseconds
                        ])
                case let .tag(tag, assetIDs, revision):
                    try db.execute(
                        sql: """
                            INSERT INTO tags (id, namespace, value, name, created_at_ms, updated_at_ms)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET namespace = excluded.namespace, value = excluded.value,
                            name = excluded.name, updated_at_ms = excluded.updated_at_ms
                            """,
                        arguments: [
                            tag.id.description, tag.name.namespace, tag.name.value, tag.name.rawValue,
                            CatalogDate.milliseconds(tag.createdAt), CatalogDate.milliseconds(tag.updatedAt)
                        ]
                    )
                    try db.execute(sql: "DELETE FROM asset_tags WHERE tag_id = ?", arguments: [tag.id.description])
                    for assetID in assetIDs {
                        let assetExists = try Bool.fetchOne(
                            db, sql: "SELECT EXISTS(SELECT 1 FROM assets WHERE id = ?)", arguments: [assetID.description]
                        ) ?? false
                        guard assetExists else { continue }
                        try db.execute(
                            sql: "INSERT INTO asset_tags (asset_id, tag_id, added_at_ms) VALUES (?, ?, ?)",
                            arguments: [assetID.description, tag.id.description, milliseconds]
                        )
                    }
                    try Self.saveRemoteEntityRevision("tag", entityID: tag.id.description, revision: revision, at: milliseconds, in: db)
                case let .savedSearch(search, revision):
                    let filter = try JSONEncoder().encode(search.filter)
                    let sort = try JSONEncoder().encode(search.sort)
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
                            search.id.description, search.name.rawValue, filterJSON, sortJSON,
                            CatalogDate.milliseconds(search.createdAt), CatalogDate.milliseconds(search.updatedAt)
                        ]
                    )
                    try Self.saveRemoteEntityRevision("saved_search", entityID: search.id.description, revision: revision, at: milliseconds, in: db)
                case let .exportReceipt(receipt, revision):
                    let assetIDs = try JSONEncoder().encode(receipt.assetIDs.map(\.description))
                    guard let assetIDsJSON = String(data: assetIDs, encoding: .utf8) else {
                        throw CatalogError.invalidPersistedValue("export_asset_ids")
                    }
                    try db.execute(sql: """
                        INSERT INTO export_receipts (id, manifest_sha256, asset_ids_json, completed_at_ms)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET manifest_sha256 = excluded.manifest_sha256,
                        asset_ids_json = excluded.asset_ids_json, completed_at_ms = excluded.completed_at_ms
                        """, arguments: [
                            receipt.id.description, receipt.manifestSHA256, assetIDsJSON,
                            CatalogDate.milliseconds(receipt.completedAt)
                        ])
                    try Self.saveRemoteEntityRevision("export_receipt", entityID: receipt.id.description, revision: revision, at: milliseconds, in: db)
                case let .backupManifest(manifest, revision):
                    try db.execute(sql: """
                        INSERT INTO backup_manifests
                            (id, manifest_sha256, recorded_at_ms, last_restore_drill_at_ms, last_restore_drill_result)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET manifest_sha256 = excluded.manifest_sha256,
                        recorded_at_ms = excluded.recorded_at_ms,
                        last_restore_drill_at_ms = excluded.last_restore_drill_at_ms,
                        last_restore_drill_result = excluded.last_restore_drill_result
                        """, arguments: [
                            manifest.id.description, manifest.manifestSHA256, CatalogDate.milliseconds(manifest.recordedAt),
                            manifest.lastRestoreDrillAt.map(CatalogDate.milliseconds), manifest.lastRestoreDrillResult
                        ])
                    try Self.saveRemoteEntityRevision("backup_manifest", entityID: manifest.id.description, revision: revision, at: milliseconds, in: db)
                }
            }
        }
    }

    private static func saveRemoteEntityRevision(
        _ entityType: String,
        entityID: String,
        revision: Int64,
        at milliseconds: Int64,
        in db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO remote_entity_state (entity_type, entity_id, remote_revision, updated_at_ms)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                remote_revision = excluded.remote_revision, updated_at_ms = excluded.updated_at_ms
            """, arguments: [entityType, entityID, revision, milliseconds])
    }

    private static func inboxID(in db: Database) throws -> FolderID {
        guard let value = try String.fetchOne(db, sql: "SELECT id FROM folders WHERE system_kind = 'inbox'"),
              let uuid = UUID(uuidString: value) else {
            throw CatalogError.missingCatalogIdentity
        }
        return FolderID(rawValue: uuid)
    }

    private static func manifestEntry(_ row: Row) throws -> CloudMigrationManifestEntry {
        guard let id = UUID(uuidString: row["asset_id"] as String) else { throw CatalogError.invalidPersistedIdentifier(row["asset_id"] as String) }
        return CloudMigrationManifestEntry(
            assetID: AssetID(rawValue: id), storageKey: try AssetStorageKey(row["storage_key"] as String),
            byteSize: row["byte_size"], sourceModifiedAt: CatalogDate.date(row["source_modified_at_ms"]),
            sha256: row["sha256"], capturedAt: CatalogDate.date(row["captured_at_ms"])
        )
    }

    private static func cloudBlob(_ row: Row) throws -> CloudBlob {
        CloudBlob(
            sha256: row["sha256"], byteSize: row["byte_size"], mediaType: row["media_type"], originalExtension: row["original_extension"],
            remoteBlobID: row["remote_blob_id"], verificationState: try decode(CloudBlobVerificationState.self, row["verification_state"]),
            lastError: row["last_error"], verifiedAt: (row["verified_at_ms"] as Int64?).map(CatalogDate.date)
        )
    }

    private static func assetState(_ row: Row) throws -> AssetCloudState {
        guard let id = UUID(uuidString: row["asset_id"] as String) else { throw CatalogError.invalidPersistedIdentifier(row["asset_id"] as String) }
        return AssetCloudState(
            assetID: AssetID(rawValue: id), blobSHA256: row["blob_sha256"], remoteRevision: row["remote_revision"],
            materializationState: try decode(OriginalMaterializationState.self, row["materialization_state"]), lastError: row["last_error"]
        )
    }

    private static func outboxEntry(_ row: Row) throws -> SyncOutboxEntry {
        guard let id = UUID(uuidString: row["id"] as String) else { throw CatalogError.invalidPersistedIdentifier(row["id"] as String) }
        return SyncOutboxEntry(
            id: id, idempotencyKey: row["idempotency_key"], operation: row["operation"], payload: row["payload"],
            state: try decode(SyncOutboxState.self, row["state"]), attemptCount: row["attempt_count"],
            nextAttemptAt: CatalogDate.date(row["next_attempt_at_ms"]), lastError: row["last_error"],
            createdAt: CatalogDate.date(row["created_at_ms"]), updatedAt: CatalogDate.date(row["updated_at_ms"])
        )
    }

    private static func conflict(_ row: Row) throws -> SyncConflict {
        guard let id = UUID(uuidString: row["id"] as String) else { throw CatalogError.invalidPersistedIdentifier(row["id"] as String) }
        return SyncConflict(
            id: id, entityType: row["entity_type"], entityID: row["entity_id"],
            localPayload: row["local_payload"], remotePayload: row["remote_payload"],
            detectedAt: CatalogDate.date(row["detected_at_ms"]), resolution: try decode(SyncConflictResolutionState.self, row["resolution"])
        )
    }

    private static func decode<T: RawRepresentable>(_ type: T.Type, _ rawValue: String) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: rawValue) else { throw CatalogError.invalidPersistedValue(rawValue) }
        return value
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit } && value == value.lowercased()
    }
}
