import Foundation

public enum VisualEvaluationSplit: String, Codable, CaseIterable, Hashable, Sendable {
    case development
    case holdout
    case regression
}

public enum VisualLearningEvaluationError: Error, Equatable, Sendable {
    case invalidFixtureIdentifier
    case invalidLatency
    case invalidCost
    case invalidConfidence
    case emptyDataset
}

/// A label-only evaluation record. It intentionally carries no image bytes,
/// file names, original paths, prompts, OCR text, or person/identity data.
/// The frozen manifest lets a model revision be scored before it is allowed to
/// reorder Framebase's human review queue.
public struct VisualEvaluationRecord: Codable, Hashable, Sendable {
    public let fixtureID: String
    public let split: VisualEvaluationSplit
    public let expectedBusinessQuality: BusinessPhotoQuality
    public let predictedBusinessQuality: BusinessPhotoQuality
    public let expectedPhotoRole: PhotoRole
    public let predictedPhotoRole: PhotoRole
    public let expectedHairlinePresentation: HairlinePresentation
    public let predictedHairlinePresentation: HairlinePresentation
    public let expectedBeforeAfterCandidate: Bool
    public let predictedBeforeAfterCandidate: Bool
    public let confidence: Double
    public let latencyMilliseconds: Int
    public let estimatedCostUSD: Double

    public init(
        fixtureID: String,
        split: VisualEvaluationSplit,
        expectedBusinessQuality: BusinessPhotoQuality,
        predictedBusinessQuality: BusinessPhotoQuality,
        expectedPhotoRole: PhotoRole,
        predictedPhotoRole: PhotoRole,
        expectedHairlinePresentation: HairlinePresentation,
        predictedHairlinePresentation: HairlinePresentation,
        expectedBeforeAfterCandidate: Bool,
        predictedBeforeAfterCandidate: Bool,
        confidence: Double,
        latencyMilliseconds: Int,
        estimatedCostUSD: Double
    ) throws {
        let normalizedFixtureID = fixtureID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFixtureID.isEmpty else { throw VisualLearningEvaluationError.invalidFixtureIdentifier }
        guard (0...1).contains(confidence) else { throw VisualLearningEvaluationError.invalidConfidence }
        guard latencyMilliseconds >= 0 else { throw VisualLearningEvaluationError.invalidLatency }
        guard estimatedCostUSD >= 0 else { throw VisualLearningEvaluationError.invalidCost }
        self.fixtureID = normalizedFixtureID
        self.split = split
        self.expectedBusinessQuality = expectedBusinessQuality
        self.predictedBusinessQuality = predictedBusinessQuality
        self.expectedPhotoRole = expectedPhotoRole
        self.predictedPhotoRole = predictedPhotoRole
        self.expectedHairlinePresentation = expectedHairlinePresentation
        self.predictedHairlinePresentation = predictedHairlinePresentation
        self.expectedBeforeAfterCandidate = expectedBeforeAfterCandidate
        self.predictedBeforeAfterCandidate = predictedBeforeAfterCandidate
        self.confidence = confidence
        self.latencyMilliseconds = latencyMilliseconds
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public struct VisualLearningScorecard: Codable, Hashable, Sendable {
    public let fixtureCount: Int
    public let assessmentLabelAgreement: Double
    public let strongPhotoPrecision: Double
    public let beforeAfterCandidatePrecision: Double
    public let hairlinePresentationAgreement: Double
    public let lowConfidenceRate: Double
    public let averageLatencyMilliseconds: Double
    public let averageCostUSD: Double

    public init(
        fixtureCount: Int,
        assessmentLabelAgreement: Double,
        strongPhotoPrecision: Double,
        beforeAfterCandidatePrecision: Double,
        hairlinePresentationAgreement: Double,
        lowConfidenceRate: Double,
        averageLatencyMilliseconds: Double,
        averageCostUSD: Double
    ) {
        self.fixtureCount = fixtureCount
        self.assessmentLabelAgreement = assessmentLabelAgreement
        self.strongPhotoPrecision = strongPhotoPrecision
        self.beforeAfterCandidatePrecision = beforeAfterCandidatePrecision
        self.hairlinePresentationAgreement = hairlinePresentationAgreement
        self.lowConfidenceRate = lowConfidenceRate
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.averageCostUSD = averageCostUSD
    }
}

public enum VisualLearningEvaluator {
    /// Scores only a named dataset split. Promotion thresholds remain an
    /// explicit human business decision; this evaluator never promotes a model.
    public static func score(
        records: [VisualEvaluationRecord],
        split: VisualEvaluationSplit,
        lowConfidenceThreshold: Double = 0.6
    ) throws -> VisualLearningScorecard {
        guard (0...1).contains(lowConfidenceThreshold) else {
            throw VisualLearningEvaluationError.invalidConfidence
        }
        let selected = records.filter { $0.split == split }
        guard !selected.isEmpty else { throw VisualLearningEvaluationError.emptyDataset }
        let count = Double(selected.count)
        let labelMatches = selected.reduce(0) { partial, record in
            partial
                + (record.expectedBusinessQuality == record.predictedBusinessQuality ? 1 : 0)
                + (record.expectedPhotoRole == record.predictedPhotoRole ? 1 : 0)
                + (record.expectedHairlinePresentation == record.predictedHairlinePresentation ? 1 : 0)
        }
        let predictedStrong = selected.filter { $0.predictedBusinessQuality == .strong }
        let strongCorrect = predictedStrong.filter { $0.expectedBusinessQuality == .strong }.count
        let predictedBeforeAfter = selected.filter(\.predictedBeforeAfterCandidate)
        let beforeAfterCorrect = predictedBeforeAfter.filter(\.expectedBeforeAfterCandidate).count
        let hairlineMatches = selected.filter { $0.expectedHairlinePresentation == $0.predictedHairlinePresentation }.count
        let lowConfidence = selected.filter { $0.confidence < lowConfidenceThreshold }.count

        return VisualLearningScorecard(
            fixtureCount: selected.count,
            assessmentLabelAgreement: Double(labelMatches) / (count * 3),
            strongPhotoPrecision: predictedStrong.isEmpty ? 0 : Double(strongCorrect) / Double(predictedStrong.count),
            beforeAfterCandidatePrecision: predictedBeforeAfter.isEmpty ? 0 : Double(beforeAfterCorrect) / Double(predictedBeforeAfter.count),
            hairlinePresentationAgreement: Double(hairlineMatches) / count,
            lowConfidenceRate: Double(lowConfidence) / count,
            averageLatencyMilliseconds: Double(selected.map(\.latencyMilliseconds).reduce(0, +)) / count,
            averageCostUSD: selected.map(\.estimatedCostUSD).reduce(0, +) / count
        )
    }
}
