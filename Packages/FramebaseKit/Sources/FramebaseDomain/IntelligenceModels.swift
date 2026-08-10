import Foundation

public enum IntelligenceValidationError: Error, Equatable, Sendable {
    case emptyAnalysisKinds
    case invalidEngine
    case invalidRequestRevision
    case invalidSchemaVersion
    case invalidDerivativeSHA256
    case invalidDerivativeDimension
    case invalidLocale
    case invalidConfidence
    case emptyRecognizedText
    case invalidBoundingBox
    case payloadKindMismatch
}

public enum AnalysisKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ocr
    case barcode
    case document
    case faceRegions
}

public enum AnalysisStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case stale
}

public struct AssetAnalysisRequest: Codable, Hashable, Sendable {
    public let assetID: AssetID
    public let kinds: Set<AnalysisKind>

    public init(assetID: AssetID, kinds: Set<AnalysisKind>) throws {
        guard !kinds.isEmpty else { throw IntelligenceValidationError.emptyAnalysisKinds }
        self.assetID = assetID
        self.kinds = kinds
    }

    public var allowsCatalogMutation: Bool { false }
}

public struct AnalysisProvenance: Codable, Hashable, Sendable {
    public let engine: String
    public let requestRevision: Int
    public let schemaVersion: Int
    public let derivativeSHA256: String
    public let derivativeMaximumPixelDimension: Int
    public let capturedAt: Date
    public let locales: [String]

    public init(
        engine: String,
        requestRevision: Int,
        schemaVersion: Int,
        derivativeSHA256: String,
        derivativeMaximumPixelDimension: Int,
        capturedAt: Date,
        locales: [String]
    ) throws {
        let normalizedEngine = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEngine.isEmpty else { throw IntelligenceValidationError.invalidEngine }
        guard requestRevision > 0 else { throw IntelligenceValidationError.invalidRequestRevision }
        guard schemaVersion > 0 else { throw IntelligenceValidationError.invalidSchemaVersion }
        guard Self.isSHA256(derivativeSHA256) else { throw IntelligenceValidationError.invalidDerivativeSHA256 }
        guard (1...1_600).contains(derivativeMaximumPixelDimension) else {
            throw IntelligenceValidationError.invalidDerivativeDimension
        }
        guard locales.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw IntelligenceValidationError.invalidLocale
        }
        self.engine = normalizedEngine
        self.requestRevision = requestRevision
        self.schemaVersion = schemaVersion
        self.derivativeSHA256 = derivativeSHA256.lowercased()
        self.derivativeMaximumPixelDimension = derivativeMaximumPixelDimension
        self.capturedAt = capturedAt
        self.locales = locales
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

public struct NormalizedBoundingBox: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public static let fullImage = try! NormalizedBoundingBox(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard (0...1).contains(x), (0...1).contains(y), width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            throw IntelligenceValidationError.invalidBoundingBox
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OCRLine: Codable, Hashable, Sendable {
    public let text: String
    public let confidence: Double
    public let boundingBox: NormalizedBoundingBox

    public init(text: String, confidence: Double, boundingBox: NormalizedBoundingBox) throws {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { throw IntelligenceValidationError.emptyRecognizedText }
        guard (0...1).contains(confidence) else { throw IntelligenceValidationError.invalidConfidence }
        self.text = normalizedText
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public enum AnalysisPayload: Codable, Hashable, Sendable {
    case ocr([OCRLine])
    case barcode(count: Int)
    case document(confidence: Double)
    case faceRegions(count: Int)

    private enum CodingKeys: String, CodingKey { case kind, ocrLines, count, confidence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(AnalysisKind.self, forKey: .kind) {
        case .ocr:
            self = .ocr(try container.decode([OCRLine].self, forKey: .ocrLines))
        case .barcode:
            self = .barcode(count: try container.decode(Int.self, forKey: .count))
        case .document:
            self = .document(confidence: try container.decode(Double.self, forKey: .confidence))
        case .faceRegions:
            self = .faceRegions(count: try container.decode(Int.self, forKey: .count))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ocr(lines):
            try container.encode(AnalysisKind.ocr, forKey: .kind)
            try container.encode(lines, forKey: .ocrLines)
        case let .barcode(count):
            try container.encode(AnalysisKind.barcode, forKey: .kind)
            try container.encode(count, forKey: .count)
        case let .document(confidence):
            try container.encode(AnalysisKind.document, forKey: .kind)
            try container.encode(confidence, forKey: .confidence)
        case let .faceRegions(count):
            try container.encode(AnalysisKind.faceRegions, forKey: .kind)
            try container.encode(count, forKey: .count)
        }
    }

    var kind: AnalysisKind {
        switch self {
        case .ocr: .ocr
        case .barcode: .barcode
        case .document: .document
        case .faceRegions: .faceRegions
        }
    }
}

public struct AssetAnalysisResult: Codable, Hashable, Sendable, CustomStringConvertible {
    public let id: UUID
    public let assetID: AssetID
    public let kind: AnalysisKind
    public let status: AnalysisStatus
    public let provenance: AnalysisProvenance
    public let payload: AnalysisPayload

    public init(
        id: UUID = UUID(),
        assetID: AssetID,
        kind: AnalysisKind,
        status: AnalysisStatus,
        provenance: AnalysisProvenance,
        payload: AnalysisPayload
    ) throws {
        guard kind == payload.kind else { throw IntelligenceValidationError.payloadKindMismatch }
        self.id = id
        self.assetID = assetID
        self.kind = kind
        self.status = status
        self.provenance = provenance
        self.payload = payload
    }

    public var description: String {
        "AssetAnalysisResult(kind: \(kind.rawValue), status: \(status.rawValue), engine: \(provenance.engine), revision: \(provenance.requestRevision), derivativeSHA256: <redacted>)"
    }
}
