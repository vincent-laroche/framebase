import Foundation
import FramebaseDomain
import GRDB

public struct CatalogVisualLearningRepository: VisualLearningRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) { self.databasePool = databasePool }

    public func store(_ assessment: PhotoAssessment) async throws {
        let evidence = String(data: try JSONEncoder().encode(assessment.evidence), encoding: .utf8)!
        let now = CatalogDate.milliseconds(Date())
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO visual_assessments (id, asset_id, business_quality, evidence_json, photo_role, hairline_presentation, confidence, rationale, provider, model_identifier, assessment_schema_version, derivative_sha256, derivative_maximum_pixel_dimension, captured_at_ms, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id, provider, model_identifier, assessment_schema_version, derivative_sha256) DO NOTHING
                """, arguments: [
                    assessment.id.uuidString.lowercased(), assessment.assetID.description, assessment.businessQuality.rawValue,
                    evidence, assessment.photoRole.rawValue, assessment.hairlinePresentation.rawValue, assessment.confidence,
                    assessment.rationale, assessment.modelRevision.provider.rawValue, assessment.modelRevision.modelIdentifier,
                    assessment.modelRevision.assessmentSchemaVersion, assessment.derivativeSHA256,
                    assessment.derivativeMaximumPixelDimension, CatalogDate.milliseconds(assessment.capturedAt), now, now
                ])
        }
    }

    public func assessments(for assetID: AssetID) async throws -> [PhotoAssessment] {
        try await databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM visual_assessments WHERE asset_id = ? ORDER BY captured_at_ms DESC", arguments: [assetID.description]).map { row in
                try PhotoAssessment(
                    id: UUID(uuidString: row["id"] as String)!, assetID: assetID,
                    businessQuality: BusinessPhotoQuality(rawValue: row["business_quality"] as String)!,
                    evidence: try JSONDecoder().decode(Set<VisualEvidenceCode>.self, from: Data((row["evidence_json"] as String).utf8)),
                    photoRole: PhotoRole(rawValue: row["photo_role"] as String)!,
                    hairlinePresentation: HairlinePresentation(rawValue: row["hairline_presentation"] as String)!,
                    confidence: row["confidence"], rationale: row["rationale"],
                    modelRevision: try VisualModelRevision(
                        provider: VisualModelProvider(rawValue: row["provider"] as String)!,
                        modelIdentifier: row["model_identifier"], assessmentSchemaVersion: row["assessment_schema_version"]
                    ), derivativeSHA256: row["derivative_sha256"],
                    derivativeMaximumPixelDimension: row["derivative_maximum_pixel_dimension"],
                    capturedAt: CatalogDate.date(row["captured_at_ms"] as Int64)
                )
            }
        }
    }

    public func record(_ review: AssessmentReview) async throws {
        let now = CatalogDate.milliseconds(Date())
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO visual_assessment_reviews (id, assessment_id, asset_id, decision, corrected_business_quality, corrected_photo_role, corrected_hairline_presentation, reviewed_at_ms, created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    review.id.uuidString.lowercased(), review.assessmentID.uuidString.lowercased(), review.assetID.description,
                    review.decision.rawValue, review.correctedBusinessQuality?.rawValue, review.correctedPhotoRole?.rawValue,
                    review.correctedHairlinePresentation?.rawValue, CatalogDate.milliseconds(review.reviewedAt), now
                ])
        }
    }

    public func reviews(for assessmentID: UUID) async throws -> [AssessmentReview] {
        try await databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM visual_assessment_reviews WHERE assessment_id = ? ORDER BY reviewed_at_ms ASC, id ASC", arguments: [assessmentID.uuidString.lowercased()]).map { row in
                try AssessmentReview(
                    id: UUID(uuidString: row["id"] as String)!, assessmentID: assessmentID,
                    assetID: AssetID(rawValue: UUID(uuidString: row["asset_id"] as String)!),
                    decision: AssessmentReviewDecision(rawValue: row["decision"] as String)!,
                    correctedBusinessQuality: (row["corrected_business_quality"] as String?).flatMap(BusinessPhotoQuality.init(rawValue:)),
                    correctedPhotoRole: (row["corrected_photo_role"] as String?).flatMap(PhotoRole.init(rawValue:)),
                    correctedHairlinePresentation: (row["corrected_hairline_presentation"] as String?).flatMap(HairlinePresentation.init(rawValue:)),
                    reviewedAt: CatalogDate.date(row["reviewed_at_ms"] as Int64)
                )
            }
        }
    }

    public func record(_ feedback: AssessmentFeedbackEvent) async throws {
        try await databasePool.write { db in
            try db.execute(sql: "INSERT INTO visual_assessment_feedback_events (id, assessment_id, review_id, outcome, captured_at_ms) VALUES (?, ?, ?, ?, ?)", arguments: [
                feedback.id.uuidString.lowercased(), feedback.assessmentID.uuidString.lowercased(), feedback.reviewID?.uuidString.lowercased(), feedback.outcome.rawValue, CatalogDate.milliseconds(feedback.capturedAt)
            ])
        }
    }

    public func feedback(for assessmentID: UUID) async throws -> [AssessmentFeedbackEvent] {
        try await databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM visual_assessment_feedback_events WHERE assessment_id = ? ORDER BY captured_at_ms ASC, id ASC", arguments: [assessmentID.uuidString.lowercased()]).map { row in
                AssessmentFeedbackEvent(
                    id: UUID(uuidString: row["id"] as String)!, assessmentID: assessmentID,
                    reviewID: (row["review_id"] as String?).flatMap(UUID.init(uuidString:)),
                    outcome: AssessmentFeedbackOutcome(rawValue: row["outcome"] as String)!,
                    capturedAt: CatalogDate.date(row["captured_at_ms"] as Int64)
                )
            }
        }
    }

    public func store(_ relationship: BeforeAfterRelationship) async throws {
        let now = CatalogDate.milliseconds(Date())
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO before_after_relationships (id, before_asset_id, after_asset_id, status, source_assessment_id, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(before_asset_id, after_asset_id) DO UPDATE SET status=excluded.status, source_assessment_id=excluded.source_assessment_id, updated_at_ms=excluded.updated_at_ms
                """, arguments: [
                    relationship.id.uuidString.lowercased(), relationship.beforeAssetID.description, relationship.afterAssetID.description,
                    relationship.status.rawValue, relationship.sourceAssessmentID?.uuidString.lowercased(),
                    CatalogDate.milliseconds(relationship.createdAt), now
                ])
        }
    }

    public func relationships(for assetID: AssetID) async throws -> [BeforeAfterRelationship] {
        try await databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM before_after_relationships WHERE before_asset_id = ? OR after_asset_id = ? ORDER BY created_at_ms ASC, id ASC", arguments: [assetID.description, assetID.description]).map { row in
                try BeforeAfterRelationship(
                    id: UUID(uuidString: row["id"] as String)!,
                    beforeAssetID: AssetID(rawValue: UUID(uuidString: row["before_asset_id"] as String)!),
                    afterAssetID: AssetID(rawValue: UUID(uuidString: row["after_asset_id"] as String)!),
                    status: BeforeAfterRelationshipStatus(rawValue: row["status"] as String)!,
                    sourceAssessmentID: (row["source_assessment_id"] as String?).flatMap(UUID.init(uuidString:)),
                    createdAt: CatalogDate.date(row["created_at_ms"] as Int64)
                )
            }
        }
    }
}
