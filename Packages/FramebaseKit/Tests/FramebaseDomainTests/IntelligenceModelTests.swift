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

    @Test("Barcode details and anonymous face geometry round-trip without identity data")
    func barcodeAndFacePayloadRoundTrip() throws {
        let barcode = try BarcodeObservation(
            symbology: "QR",
            payload: "PRIVATE-BARCODE",
            confidence: 0.9,
            boundingBox: .fullImage
        )
        let face = try FaceRegion(boundingBox: .fullImage, confidence: 0.8)
        let payloads: [AnalysisPayload] = [
            .barcode(count: 1, observations: [barcode]),
            .faceRegions(count: 1, regions: [face])
        ]

        for payload in payloads {
            #expect(try JSONDecoder().decode(AnalysisPayload.self, from: JSONEncoder().encode(payload)) == payload)
        }
    }

    @Test("Initial count-only payloads remain readable")
    func legacyCountOnlyPayloadsRemainReadable() throws {
        let barcode = try JSONDecoder().decode(
            AnalysisPayload.self,
            from: Data(#"{"kind":"barcode","count":2}"#.utf8)
        )
        let faces = try JSONDecoder().decode(
            AnalysisPayload.self,
            from: Data(#"{"kind":"faceRegions","count":3}"#.utf8)
        )

        #expect(barcode == .barcode(count: 2, observations: []))
        #expect(faces == .faceRegions(count: 3, regions: []))
    }
}
