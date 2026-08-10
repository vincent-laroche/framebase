import Foundation
import FramebaseDomain
import GRDB

public struct CatalogIntelligenceRepository: IntelligenceRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) { self.databasePool = databasePool }

    public func store(_ result: AssetAnalysisResult) async throws {
        let encoder = JSONEncoder()
        let payload = String(data: try encoder.encode(result.payload), encoding: .utf8)!
        let locales = String(data: try encoder.encode(result.provenance.locales), encoding: .utf8)!
        let now = CatalogDate.milliseconds(Date())
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO analysis_results (id, asset_id, kind, status, engine, request_revision, schema_version, derivative_sha256, derivative_maximum_pixel_dimension, captured_at_ms, locales_json, payload_json, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id, kind, engine, request_revision, derivative_sha256) DO UPDATE SET status=excluded.status, payload_json=excluded.payload_json, locales_json=excluded.locales_json, updated_at_ms=excluded.updated_at_ms
                """, arguments: [result.id.uuidString.lowercased(), result.assetID.description, result.kind.rawValue, result.status.rawValue, result.provenance.engine, result.provenance.requestRevision, result.provenance.schemaVersion, result.provenance.derivativeSHA256, result.provenance.derivativeMaximumPixelDimension, CatalogDate.milliseconds(result.provenance.capturedAt), locales, payload, now, now])
            guard case let .ocr(lines) = result.payload else { return }
            guard let resultID = try String.fetchOne(db, sql: "SELECT id FROM analysis_results WHERE asset_id=? AND kind=? AND engine=? AND request_revision=? AND derivative_sha256=?", arguments: [result.assetID.description, result.kind.rawValue, result.provenance.engine, result.provenance.requestRevision, result.provenance.derivativeSHA256]) else { return }
            try db.execute(sql: "DELETE FROM analysis_text_lines WHERE result_id = ?", arguments: [resultID])
            for (index, line) in lines.enumerated() { try db.execute(sql: "INSERT INTO analysis_text_lines (result_id, line_index, normalized_text) VALUES (?, ?, ?)", arguments: [resultID, index, line.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)]) }
        }
    }

    public func results(for assetID: AssetID) async throws -> [AssetAnalysisResult] {
        try await databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM analysis_results WHERE asset_id = ? ORDER BY captured_at_ms DESC", arguments: [assetID.description]).map { row in
                let provenance = try AnalysisProvenance(engine: row["engine"], requestRevision: row["request_revision"], schemaVersion: row["schema_version"], derivativeSHA256: row["derivative_sha256"], derivativeMaximumPixelDimension: row["derivative_maximum_pixel_dimension"], capturedAt: CatalogDate.date(row["captured_at_ms"] as Int64), locales: try JSONDecoder().decode([String].self, from: Data((row["locales_json"] as String).utf8)))
                return try AssetAnalysisResult(id: UUID(uuidString: row["id"] as String)!, assetID: assetID, kind: AnalysisKind(rawValue: row["kind"] as String)!, status: AnalysisStatus(rawValue: row["status"] as String)!, provenance: provenance, payload: try JSONDecoder().decode(AnalysisPayload.self, from: Data((row["payload_json"] as String).utf8)))
            }
        }
    }

    public func markStaleIfSourceDigestDiffers(assetID: AssetID, digest: String) async throws {
        try await databasePool.write { db in try db.execute(sql: "UPDATE analysis_results SET status = 'stale', updated_at_ms = ? WHERE asset_id = ? AND derivative_sha256 != ? AND status = 'succeeded'", arguments: [CatalogDate.milliseconds(Date()), assetID.description, digest.lowercased()]) }
    }

    public func assetIDsMatchingOCR(_ text: String) async throws -> [AssetID] {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return try await databasePool.read { db in try String.fetchAll(db, sql: "SELECT DISTINCT r.asset_id FROM analysis_results r JOIN analysis_text_lines l ON l.result_id = r.id WHERE r.status = 'succeeded' AND l.normalized_text LIKE ? ORDER BY r.asset_id", arguments: ["%\(normalized)%"]).compactMap(UUID.init(uuidString:)).map(AssetID.init(rawValue:)) }
    }
}
