import Foundation

/// Requests identify a bounded derivative by digest. They contain no raw bytes,
/// original path, credential, or catalog-mutation authority.
public struct VisualAssessmentRequest: Codable, Hashable, Sendable {
    public let assetID: AssetID
    public let derivativeSHA256: String
    public let derivativeMaximumPixelDimension: Int
    public let modelRevision: VisualModelRevision

    public init(
        assetID: AssetID,
        derivativeSHA256: String,
        derivativeMaximumPixelDimension: Int,
        modelRevision: VisualModelRevision
    ) throws {
        _ = try PhotoAssessment(
            assetID: assetID,
            businessQuality: .needsReview,
            evidence: [],
            photoRole: .unclear,
            hairlinePresentation: .unclear,
            confidence: 0,
            rationale: "Validation placeholder",
            modelRevision: modelRevision,
            derivativeSHA256: derivativeSHA256,
            derivativeMaximumPixelDimension: derivativeMaximumPixelDimension,
            capturedAt: .distantPast
        )
        self.assetID = assetID
        self.derivativeSHA256 = derivativeSHA256.lowercased()
        self.derivativeMaximumPixelDimension = derivativeMaximumPixelDimension
        self.modelRevision = modelRevision
    }

    public var allowsCatalogMutation: Bool { false }
}

public protocol VisualAssessmentService: Sendable {
    func assess(_ request: VisualAssessmentRequest, derivativeURL: URL) async throws -> PhotoAssessment
}

public protocol VisualLearningRepository: Sendable {
    func store(_ assessment: PhotoAssessment) async throws
    func assessments(for assetID: AssetID) async throws -> [PhotoAssessment]
    func record(_ review: AssessmentReview) async throws
    func reviews(for assessmentID: UUID) async throws -> [AssessmentReview]
    func record(_ feedback: AssessmentFeedbackEvent) async throws
    func feedback(for assessmentID: UUID) async throws -> [AssessmentFeedbackEvent]
    func store(_ relationship: BeforeAfterRelationship) async throws
    func relationships(for assetID: AssetID) async throws -> [BeforeAfterRelationship]
}
