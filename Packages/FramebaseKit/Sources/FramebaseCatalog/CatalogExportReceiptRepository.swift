import Foundation
import FramebaseDomain
import GRDB

public struct CatalogExportReceiptRepository: ExportReceiptRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    public func record(_ receipt: AssetExportReceipt) async throws {
        guard Self.isSHA256(receipt.manifestSHA256) else {
            throw CatalogError.invalidPersistedValue("export_manifest_sha256")
        }
        let encodedIDs = try JSONEncoder().encode(receipt.assetIDs.map(\.description))
        guard let assetIDsJSON = String(data: encodedIDs, encoding: .utf8) else {
            throw CatalogError.invalidPersistedValue("export_asset_ids")
        }
        try await databasePool.write { db in
            try db.execute(
                sql: "INSERT INTO export_receipts (id, manifest_sha256, asset_ids_json, completed_at_ms) VALUES (?, ?, ?, ?)",
                arguments: [
                    receipt.id.description,
                    receipt.manifestSHA256,
                    assetIDsJSON,
                    CatalogDate.milliseconds(receipt.completedAt)
                ]
            )
        }
    }

    public func receipts() async throws -> [AssetExportReceipt] {
        try await databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM export_receipts ORDER BY completed_at_ms DESC, id DESC")
            return try rows.map { row in
                let idText: String = row["id"]
                let id = try Self.exportReceiptID(idText)
                let assetIDsJSON: String = row["asset_ids_json"]
                let assetIDTexts = try JSONDecoder().decode([String].self, from: Data(assetIDsJSON.utf8))
                return AssetExportReceipt(
                    id: id,
                    manifestSHA256: row["manifest_sha256"],
                    assetIDs: try assetIDTexts.map(Self.assetID),
                    completedAt: CatalogDate.date(row["completed_at_ms"])
                )
            }
        }
    }

    private static func exportReceiptID(_ value: String) throws -> ExportReceiptID {
        guard let rawValue = UUID(uuidString: value) else { throw CatalogError.invalidPersistedIdentifier(value) }
        return ExportReceiptID(rawValue: rawValue)
    }

    private static func assetID(_ value: String) throws -> AssetID {
        guard let rawValue = UUID(uuidString: value) else { throw CatalogError.invalidPersistedIdentifier(value) }
        return AssetID(rawValue: rawValue)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
