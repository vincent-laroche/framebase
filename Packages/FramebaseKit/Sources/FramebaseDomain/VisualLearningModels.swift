import Foundation

public enum VisualLearningValidationError: Error, Equatable, Sendable {
    case invalidModelIdentifier
    case invalidAssessmentSchemaVersion
    case invalidDerivativeSHA256
    case invalidDerivativeDimension
    case invalidConfidence
    case invalidRationale
    case duplicateBeforeAfterAsset
    case invalidReviewCorrection
}

/// The result is a review recommendation, never an organizing command.
public enum BusinessPhotoQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case strong
    case usable
    case weak
    case needsReview
}

public enum VisualEvidenceCode: String, Codable, CaseIterable, Hashable, Sendable {
    case sharp
    case wellLit
    case hairlineClear
    case productVisible
    case beforeAfterContext
    case croppedPoorly
    case uncertain
}

public enum PhotoRole: String, Codable, CaseIterable, Hashable, Sendable {
    case beforeCandidate
    case afterCandidate
    case comparisonCandidate
    case other
    case unclear
}

/// This is a visual presentation label for the asset, not a biometric or
/// medical inference about a person.
public enum HairlinePresentation: String, Codable, CaseIterable, Hashable, Sendable {
    case clearlyVisible
    case partiallyVisible
    case notVisible
    case unclear
}

public enum VisualModelProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case anthropic
    case local
}

public struct VisualModelRevision: Codable, Hashable, Sendable {
    public let provider: VisualModelProvider
    public let modelIdentifier: String
    public let assessmentSchemaVersion: Int

    public init(provider: VisualModelProvider, modelIdentifier: String, assessmentSchemaVersion: Int) throws {
        let identifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw VisualLearningValidationError.invalidModelIdentifier }
        guard assessmentSchemaVersion > 0 else { throw VisualLearningValidationError.invalidAssessmentSchemaVersion }
        self.provider = provider
        self.modelIdentifier = identifier
        self.assessmentSchemaVersion = assessmentSchemaVersion
    }
}

public struct PhotoAssessment: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let maximumRationaleLength = 240

    public let id: UUID
    public let assetID: AssetID
    public let businessQuality: BusinessPhotoQuality
    public let evidence: Set<VisualEvidenceCode>
    public let photoRole: PhotoRole
    public let hairlinePresentation: HairlinePresentation
    public let confidence: Double
    public let rationale: String
    public let modelRevision: VisualModelRevision
    public let derivativeSHA256: String
    public let derivativeMaximumPixelDimension: Int
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        assetID: AssetID,
        businessQuality: BusinessPhotoQuality,
        evidence: Set<VisualEvidenceCode>,
        photoRole: PhotoRole,
        hairlinePresentation: HairlinePresentation,
        confidence: Double,
        rationale: String,
        modelRevision: VisualModelRevision,
        derivativeSHA256: String,
        derivativeMaximumPixelDimension: Int,
        capturedAt: Date
    ) throws {
        let normalizedRationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRationale.isEmpty, normalizedRationale.count <= Self.maximumRationaleLength else {
            throw VisualLearningValidationError.invalidRationale
        }
        guard (0...1).contains(confidence) else { throw VisualLearningValidationError.invalidConfidence }
        guard Self.isSHA256(derivativeSHA256) else { throw VisualLearningValidationError.invalidDerivativeSHA256 }
        guard (1...1_600).contains(derivativeMaximumPixelDimension) else {
            throw VisualLearningValidationError.invalidDerivativeDimension
        }
        self.id = id
        self.assetID = assetID
        self.businessQuality = businessQuality
        self.evidence = evidence
        self.photoRole = photoRole
        self.hairlinePresentation = hairlinePresentation
        self.confidence = confidence
        self.rationale = normalizedRationale
        self.modelRevision = modelRevision
        self.derivativeSHA256 = derivativeSHA256.lowercased()
        self.derivativeMaximumPixelDimension = derivativeMaximumPixelDimension
        self.capturedAt = capturedAt
    }

    public var allowsCatalogMutation: Bool { false }

    public var description: String {
        "PhotoAssessment(quality: \(businessQuality.rawValue), role: \(photoRole.rawValue), provider: \(modelRevision.provider.rawValue), model: \(modelRevision.modelIdentifier), rationale: <redacted>)"
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

public enum AssessmentReviewDecision: String, Codable, CaseIterable, Hashable, Sendable {
    case unreviewed
    case accepted
    case corrected
    case rejected
    case needsMoreContext
}

/// Corrections are append-only review evidence. They never overwrite the
/// originating assessment or cause organization changes.
public struct AssessmentReview: Codable, Hashable, Sendable {
    public let id: UUID
    public let assessmentID: UUID
    public let assetID: AssetID
    public let decision: AssessmentReviewDecision
    public let correctedBusinessQuality: BusinessPhotoQuality?
    public let correctedPhotoRole: PhotoRole?
    public let correctedHairlinePresentation: HairlinePresentation?
    public let reviewedAt: Date

    public init(
        id: UUID = UUID(),
        assessmentID: UUID,
        assetID: AssetID,
        decision: AssessmentReviewDecision,
        correctedBusinessQuality: BusinessPhotoQuality? = nil,
        correctedPhotoRole: PhotoRole? = nil,
        correctedHairlinePresentation: HairlinePresentation? = nil,
        reviewedAt: Date
    ) throws {
        let hasCorrection = correctedBusinessQuality != nil || correctedPhotoRole != nil || correctedHairlinePresentation != nil
        guard decision == .corrected ? hasCorrection : !hasCorrection else {
            throw VisualLearningValidationError.invalidReviewCorrection
        }
        self.id = id
        self.assessmentID = assessmentID
        self.assetID = assetID
        self.decision = decision
        self.correctedBusinessQuality = correctedBusinessQuality
        self.correctedPhotoRole = correctedPhotoRole
        self.correctedHairlinePresentation = correctedHairlinePresentation
        self.reviewedAt = reviewedAt
    }
}

public enum BeforeAfterRelationshipStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case candidate
    case confirmed
    case rejected
    case superseded
}

public struct BeforeAfterRelationship: Codable, Hashable, Sendable {
    public let id: UUID
    public let beforeAssetID: AssetID
    public let afterAssetID: AssetID
    public let status: BeforeAfterRelationshipStatus
    public let sourceAssessmentID: UUID?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        beforeAssetID: AssetID,
        afterAssetID: AssetID,
        status: BeforeAfterRelationshipStatus,
        sourceAssessmentID: UUID? = nil,
        createdAt: Date
    ) throws {
        guard beforeAssetID != afterAssetID else { throw VisualLearningValidationError.duplicateBeforeAfterAsset }
        self.id = id
        self.beforeAssetID = beforeAssetID
        self.afterAssetID = afterAssetID
        self.status = status
        self.sourceAssessmentID = sourceAssessmentID
        self.createdAt = createdAt
    }

    public var allowsCatalogMutation: Bool { false }
}

public enum AssessmentFeedbackOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case helpful
    case notHelpful
    case uncertain
}

public struct AssessmentFeedbackEvent: Codable, Hashable, Sendable {
    public let id: UUID
    public let assessmentID: UUID
    public let reviewID: UUID?
    public let outcome: AssessmentFeedbackOutcome
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        assessmentID: UUID,
        reviewID: UUID? = nil,
        outcome: AssessmentFeedbackOutcome,
        capturedAt: Date
    ) {
        self.id = id
        self.assessmentID = assessmentID
        self.reviewID = reviewID
        self.outcome = outcome
        self.capturedAt = capturedAt
    }
}
