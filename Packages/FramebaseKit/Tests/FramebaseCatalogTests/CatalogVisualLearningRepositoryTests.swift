import Foundation
import FramebaseCatalog
import FramebaseDomain
import FramebaseTestSupport
import Testing

@Suite("Catalog visual learning repository", .serialized)
struct CatalogVisualLearningRepositoryTests {
    @Test("Assessment provenance is idempotent while reviews and feedback remain append-only after reopen")
    func assessmentReviewHistoryReopensSafely() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        let otherAsset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAssets([asset, otherAsset])
        let assessment = try fixtureAssessment(assetID: asset.id)

        try await database.visualLearning.store(assessment)
        try await database.visualLearning.store(assessment)
        #expect(try await database.visualLearning.assessments(for: asset.id) == [assessment])

        let review = try AssessmentReview(
            assessmentID: assessment.id,
            assetID: asset.id,
            decision: .corrected,
            correctedBusinessQuality: .usable,
            reviewedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let feedback = AssessmentFeedbackEvent(
            assessmentID: assessment.id,
            reviewID: review.id,
            outcome: .helpful,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let relationship = try BeforeAfterRelationship(
            beforeAssetID: otherAsset.id,
            afterAssetID: asset.id,
            status: .candidate,
            sourceAssessmentID: assessment.id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_003)
        )

        try await database.visualLearning.record(review)
        try await database.visualLearning.record(feedback)
        try await database.visualLearning.store(relationship)

        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)
        #expect(try await reopened.visualLearning.assessments(for: asset.id) == [assessment])
        #expect(try await reopened.visualLearning.reviews(for: assessment.id) == [review])
        #expect(try await reopened.visualLearning.feedback(for: assessment.id) == [feedback])
        #expect(try await reopened.visualLearning.relationships(for: asset.id) == [relationship])
    }

    private func fixtureAssessment(assetID: AssetID) throws -> PhotoAssessment {
        try PhotoAssessment(
            id: UUID(uuidString: "12345678-1234-1234-1234-1234567890AF")!,
            assetID: assetID,
            businessQuality: .strong,
            evidence: [.sharp, .hairlineClear, .productVisible],
            photoRole: .afterCandidate,
            hairlinePresentation: .clearlyVisible,
            confidence: 0.9,
            rationale: "Sharp product view",
            modelRevision: try VisualModelRevision(provider: .anthropic, modelIdentifier: "anthropic/claude-sonnet-4-5", assessmentSchemaVersion: 1),
            derivativeSHA256: String(repeating: "a", count: 64),
            derivativeMaximumPixelDimension: 1_600,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
