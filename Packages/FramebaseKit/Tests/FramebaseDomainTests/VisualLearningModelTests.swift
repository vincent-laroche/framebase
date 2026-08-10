import Foundation
import FramebaseDomain
import Testing

@Suite("Visual photo learning contracts")
struct VisualLearningModelTests {
    private let assetID = AssetID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)
    private let otherAssetID = AssetID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-1234567890AC")!)

    @Test("Assessment requires bounded rationale and model provenance")
    func assessmentValidation() throws {
        #expect(throws: VisualLearningValidationError.self) {
            try PhotoAssessment(
                assetID: assetID,
                businessQuality: .strong,
                evidence: [.sharp],
                photoRole: .afterCandidate,
                hairlinePresentation: .clearlyVisible,
                confidence: 0.9,
                rationale: String(repeating: "x", count: 241),
                modelRevision: try VisualModelRevision(provider: .anthropic, modelIdentifier: "", assessmentSchemaVersion: 1),
                derivativeSHA256: String(repeating: "a", count: 64),
                derivativeMaximumPixelDimension: 1_600,
                capturedAt: .now
            )
        }
    }

    @Test("Assessments, review history, and before-after candidates round-trip without mutation authority")
    func codableAndNonDestructiveContracts() throws {
        let assessment = try fixtureAssessment()
        let review = try AssessmentReview(
            assessmentID: assessment.id,
            assetID: assetID,
            decision: .corrected,
            correctedBusinessQuality: .usable,
            correctedPhotoRole: .comparisonCandidate,
            correctedHairlinePresentation: .partiallyVisible,
            reviewedAt: .now
        )
        let relationship = try BeforeAfterRelationship(
            beforeAssetID: assetID,
            afterAssetID: otherAssetID,
            status: .candidate,
            sourceAssessmentID: assessment.id,
            createdAt: .now
        )
        let feedback = AssessmentFeedbackEvent(
            assessmentID: assessment.id,
            reviewID: review.id,
            outcome: .helpful,
            capturedAt: .now
        )

        #expect(try JSONDecoder().decode(PhotoAssessment.self, from: JSONEncoder().encode(assessment)) == assessment)
        #expect(try JSONDecoder().decode(AssessmentReview.self, from: JSONEncoder().encode(review)) == review)
        #expect(try JSONDecoder().decode(BeforeAfterRelationship.self, from: JSONEncoder().encode(relationship)) == relationship)
        #expect(try JSONDecoder().decode(AssessmentFeedbackEvent.self, from: JSONEncoder().encode(feedback)) == feedback)
        #expect(!assessment.allowsCatalogMutation)
        #expect(!relationship.allowsCatalogMutation)
    }

    @Test("Visual assessment descriptions redact rationale and do not model identity")
    func assessmentDescriptionIsRedacted() throws {
        let assessment = try fixtureAssessment(rationale: "PRIVATE CUSTOMER CONTEXT")

        #expect(!assessment.description.contains("PRIVATE CUSTOMER CONTEXT"))
        #expect(VisualEvidenceCode.allCases.contains(.hairlineClear))
        #expect(!VisualEvidenceCode.allCases.map(\.rawValue).contains("face"))
    }

    private func fixtureAssessment(rationale: String = "Sharp, useful product view") throws -> PhotoAssessment {
        try PhotoAssessment(
            assetID: assetID,
            businessQuality: .strong,
            evidence: [.sharp, .hairlineClear, .productVisible],
            photoRole: .afterCandidate,
            hairlinePresentation: .clearlyVisible,
            confidence: 0.9,
            rationale: rationale,
            modelRevision: try VisualModelRevision(
                provider: .anthropic,
                modelIdentifier: "anthropic/claude-sonnet-4-5",
                assessmentSchemaVersion: 1
            ),
            derivativeSHA256: String(repeating: "a", count: 64),
            derivativeMaximumPixelDimension: 1_600,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
