import Foundation
import FramebaseCatalog
import FramebaseDomain
import FramebaseTestSupport
import Testing

@Suite("Catalog intelligence repository", .serialized)
struct CatalogIntelligenceRepositoryTests {
    @Test("Analysis persistence is idempotent, searchable, and becomes stale when its derivative changes")
    func persistenceSearchAndStaleState() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let result = try fixtureResult(assetID: asset.id, digest: String(repeating: "a", count: 64))

        try await database.intelligence.store(result)
        try await database.intelligence.store(result)

        #expect(try await database.intelligence.assetIDsMatchingOCR("framebase") == [asset.id])
        #expect(try await database.intelligence.results(for: asset.id).count == 1)

        try await database.intelligence.markStaleIfSourceDigestDiffers(
            assetID: asset.id,
            digest: String(repeating: "b", count: 64)
        )
        #expect(try await database.intelligence.results(for: asset.id).first?.status == .stale)

        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)
        #expect(try await reopened.intelligence.results(for: asset.id).first?.provenance.derivativeSHA256 == String(repeating: "a", count: 64))
        #expect(try await reopened.intelligence.assetIDsMatchingOCR("PRIVATE") == [])
    }

    private func fixtureResult(assetID: AssetID, digest: String) throws -> AssetAnalysisResult {
        let provenance = try AnalysisProvenance(
            engine: "Apple Vision",
            requestRevision: 3,
            schemaVersion: 1,
            derivativeSHA256: digest,
            derivativeMaximumPixelDimension: 1_600,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            locales: ["en"]
        )
        return try AssetAnalysisResult(
            assetID: assetID,
            kind: .ocr,
            status: .succeeded,
            provenance: provenance,
            payload: .ocr([try OCRLine(text: "Framebase catalog", confidence: 0.95, boundingBox: .fullImage)])
        )
    }
}
