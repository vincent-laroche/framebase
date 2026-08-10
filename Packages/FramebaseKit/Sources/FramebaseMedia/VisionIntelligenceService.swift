import Foundation
import FramebaseDomain
import Vision

public actor VisionIntelligenceService: IntelligenceService {
    private let derivativeProvider: IntelligenceDerivativeProvider

    public init(derivativeProvider: IntelligenceDerivativeProvider = .init()) { self.derivativeProvider = derivativeProvider }

    public func analyze(_ request: AssetAnalysisRequest, sourceURL: URL) async throws -> [AssetAnalysisResult] {
        try Task.checkCancellation()
        let derivative = try derivativeProvider.makeDerivative(from: sourceURL)
        guard let image = CGImageSourceCreateWithData(derivative.data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(image, 0, nil) else { throw IntelligenceDerivativeError.decodeFailed }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        var results: [AssetAnalysisResult] = []
        for kind in request.kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            switch kind {
            case .ocr:
                let visionRequest = VNRecognizeTextRequest()
                visionRequest.recognitionLevel = .accurate
                visionRequest.usesLanguageCorrection = true
                try handler.perform([visionRequest])
                let lines = try (visionRequest.results ?? []).compactMap { observation -> OCRLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return try OCRLine(text: candidate.string, confidence: Double(candidate.confidence), boundingBox: try NormalizedBoundingBox(x: observation.boundingBox.origin.x, y: observation.boundingBox.origin.y, width: observation.boundingBox.size.width, height: observation.boundingBox.size.height))
                }
                results.append(try result(assetID: request.assetID, kind: .ocr, derivative: derivative, revision: visionRequest.revision, locales: visionRequest.recognitionLanguages, payload: .ocr(lines)))
            case .barcode:
                let visionRequest = VNDetectBarcodesRequest()
                try handler.perform([visionRequest])
                let observations = try (visionRequest.results ?? []).map { observation in
                    try BarcodeObservation(
                        symbology: observation.symbology.rawValue,
                        payload: observation.payloadStringValue,
                        confidence: Double(observation.confidence),
                        boundingBox: try NormalizedBoundingBox(
                            x: observation.boundingBox.origin.x,
                            y: observation.boundingBox.origin.y,
                            width: observation.boundingBox.size.width,
                            height: observation.boundingBox.size.height
                        )
                    )
                }
                results.append(try result(assetID: request.assetID, kind: .barcode, derivative: derivative, revision: visionRequest.revision, locales: [], payload: .barcode(count: observations.count, observations: observations)))
            case .faceRegions:
                // `faceRegions` remains decodable for existing result records,
                // but is intentionally not an active Vision capability.
                continue
            case .document:
                let visionRequest = VNDetectDocumentSegmentationRequest()
                try handler.perform([visionRequest])
                let confidence: Double = (visionRequest.results?.isEmpty == false) ? 1 : 0
                results.append(try result(assetID: request.assetID, kind: .document, derivative: derivative, revision: visionRequest.revision, locales: [], payload: .document(confidence: confidence)))
            }
        }
        return results
    }

    private func result(assetID: AssetID, kind: AnalysisKind, derivative: AnalysisDerivative, revision: Int, locales: [String], payload: AnalysisPayload) throws -> AssetAnalysisResult {
        try AssetAnalysisResult(assetID: assetID, kind: kind, status: .succeeded, provenance: AnalysisProvenance(engine: "Apple Vision", requestRevision: revision, schemaVersion: 1, derivativeSHA256: derivative.sha256, derivativeMaximumPixelDimension: IntelligenceDerivativeProvider.maximumPixelDimension, capturedAt: .now, locales: locales), payload: payload)
    }
}
