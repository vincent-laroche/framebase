import Foundation
import FramebaseDomain
import Testing

@Suite("Intelligence provenance contracts")
struct IntelligenceModelTests {
    private let assetID = AssetID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)

    @Test("Provenance requires a SHA-256 derivative digest and request revision")
    func provenanceValidation() {
        #expect(throws: IntelligenceValidationError.self) {
            try AnalysisProvenance(
                engine: "Apple Vision",
                requestRevision: 0,
                schemaVersion: 1,
                derivativeSHA256: "not-a-digest",
                derivativeMaximumPixelDimension: 1_600,
                capturedAt: .now,
                locales: ["en"]
            )
        }
    }

    @Test("Analysis requests cannot carry catalog mutation authority")
    func requestIsAlwaysReadOnly() throws {
        let request = try AssetAnalysisRequest(assetID: assetID, kinds: [.ocr, .barcode])

        #expect(!request.allowsCatalogMutation)
    }

    @Test("Debug descriptions redact recognized text")
    func resultDebugDescriptionIsRedacted() throws {
        let provenance = try AnalysisProvenance(
            engine: "Apple Vision",
            requestRevision: 3,
            schemaVersion: 1,
            derivativeSHA256: String(repeating: "a", count: 64),
            derivativeMaximumPixelDimension: 1_600,
            capturedAt: .now,
            locales: ["en"]
        )
        let result = try AssetAnalysisResult(
            assetID: assetID,
            kind: .ocr,
            status: .succeeded,
            provenance: provenance,
            payload: .ocr([try OCRLine(text: "PRIVATE OCR CONTENT", confidence: 0.9, boundingBox: .fullImage)])
        )

        #expect(!result.description.contains("PRIVATE OCR CONTENT"))
    }
}
