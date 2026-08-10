import Foundation
import FramebaseDomain
import GRDB

public struct CatalogBackupManifestRepository: BackupManifestRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func record(_ manifest: BackupManifest) async throws {
        guard Self.validSHA256(manifest.manifestSHA256) else {
            throw CatalogError.invalidPersistedValue("backup_manifest_sha256")
        }
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO backup_manifests
                    (id, manifest_sha256, recorded_at_ms, last_restore_drill_at_ms, last_restore_drill_result)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    manifest.id.description, manifest.manifestSHA256, CatalogDate.milliseconds(manifest.recordedAt),
                    manifest.lastRestoreDrillAt.map(CatalogDate.milliseconds), manifest.lastRestoreDrillResult
                ])
        }
    }

    public func manifests() async throws -> [BackupManifest] {
        try await databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM backup_manifests ORDER BY recorded_at_ms DESC, id DESC").map { row in
                guard let uuid = UUID(uuidString: row["id"] as String) else {
                    throw CatalogError.invalidPersistedIdentifier(row["id"] as String)
                }
                return BackupManifest(
                    id: BackupManifestID(rawValue: uuid), manifestSHA256: row["manifest_sha256"],
                    recordedAt: CatalogDate.date(row["recorded_at_ms"]),
                    lastRestoreDrillAt: (row["last_restore_drill_at_ms"] as Int64?).map(CatalogDate.date),
                    lastRestoreDrillResult: row["last_restore_drill_result"]
                )
            }
        }
    }

    public func recordRestoreDrill(manifestID: BackupManifestID, result: String, at date: Date = .now) async throws {
        let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 240 else {
            throw CatalogError.invalidPersistedValue("backup_restore_drill_result")
        }
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE backup_manifests SET last_restore_drill_at_ms = ?, last_restore_drill_result = ? WHERE id = ?",
                arguments: [CatalogDate.milliseconds(date), normalized, manifestID.description]
            )
            guard db.changesCount == 1 else { throw CatalogError.invalidPersistedValue("backup_manifest") }
        }
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}
