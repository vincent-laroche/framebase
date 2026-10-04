import Foundation
import FramebaseDomain
import GRDB

extension CatalogDatabase: ScreenshotIntakeCatalog, OriginalReceiveCatalog {
    public var inboxFolderID: FolderID { inboxID }

    public func assetID(forContentSHA256 sha256: String) async throws -> AssetID? {
        let hash = try Self.normalizedContentSHA256(sha256)
        return try await databasePool.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT asset_id FROM asset_content_identity WHERE sha256 = ?",
                arguments: [hash]
            ) else {
                return nil
            }
            guard let uuid = UUID(uuidString: raw) else {
                throw CatalogError.invalidPersistedIdentifier(raw)
            }
            return AssetID(rawValue: uuid)
        }
    }

    public func asset(id: AssetID) async throws -> Asset? {
        try await assets.asset(id: id)
    }

    public func insertScreenshot(_ asset: Asset, contentSHA256: String) async throws {
        try await insertOriginal(asset, contentSHA256: contentSHA256)
    }

    /// Inserts the asset and its original-byte SHA-256 in one write.
    /// A second insert of the same bytes rolls back and reports a duplicate.
    public func ensureRootFolder(named name: String) async throws -> FolderID {
        let folderName = try FolderName(name)
        let snapshot = try await folders.treeSnapshot()
        if let existing = snapshot.folders.first(where: {
            $0.parentFolderID == nil && $0.name.rawValue.compare(folderName.rawValue, options: .caseInsensitive) == .orderedSame
        }) {
            return existing.id
        }
        return try await folders.createFolder(named: folderName, in: nil).id
    }

    public func insertOriginal(_ asset: Asset, contentSHA256: String) async throws {
        let hash = try Self.normalizedContentSHA256(contentSHA256)
        guard asset.fileSize > 0 else {
            throw CatalogError.invalidPersistedValue("content_byte_size")
        }
        let record = try AssetRecord(asset: asset, originalAvailable: true)
        let recordedAt = CatalogDate.milliseconds(Date())
        try await databasePool.write { db in
            do {
                try record.insert(db)
                try db.execute(
                    sql: """
                        INSERT INTO asset_content_identity (sha256, asset_id, byte_size, recorded_at_ms)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [hash, asset.id.description, asset.fileSize, recordedAt]
                )
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                throw ScreenshotContentIdentityError.duplicateContent
            }
        }
    }

    public func storeAnalysis(_ result: AssetAnalysisResult) async throws {
        guard result.kind == .ocr else { return }
        try await intelligence.store(result)
    }

    public func succeededOCRText(for assetID: AssetID) async throws -> String? {
        let results = try await intelligence.results(for: assetID)
        guard let latest = results.first(where: { $0.kind == .ocr && $0.status == .succeeded }) else {
            return nil
        }
        guard case let .ocr(lines) = latest.payload else { return "" }
        return lines.map(\.text).joined(separator: "\n")
    }

    static func normalizedContentSHA256(_ value: String) throws -> String {
        let hash = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw ScreenshotContentIdentityError.invalidContentSHA256
        }
        return hash
    }
}
