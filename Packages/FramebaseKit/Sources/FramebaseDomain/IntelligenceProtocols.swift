import Foundation

public protocol IntelligenceService: Sendable {
    func analyze(_ request: AssetAnalysisRequest, sourceURL: URL) async throws -> [AssetAnalysisResult]
}
