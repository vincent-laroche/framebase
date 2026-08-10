import Foundation

public struct WorkflowPlanner: Sendable {
    public init() {}

    public func plan(definition: WorkflowDefinition, snapshot: WorkflowInputSnapshot) throws -> WorkflowPlan {
        let steps = definition.actions.enumerated().map { index, action in
            WorkflowPlanStep(sequence: index + 1, action: action, targetAssetIDs: snapshot.assetIDs)
        }
        let canonical = [
            definition.id.uuidString.lowercased(),
            definition.schemaVersion.description,
            definition.trigger.rawValue,
            definition.actions.map(\.canonicalValue).joined(separator: "|"),
            snapshot.assetIDs.map(\.description).joined(separator: ","),
            snapshot.catalogRevision.description,
            snapshot.sourceFingerprint
        ].joined(separator: ":")
        return WorkflowPlan(
            definitionID: definition.id,
            definitionSchemaVersion: definition.schemaVersion,
            snapshot: snapshot,
            steps: steps,
            idempotencyKey: WorkflowFingerprint.sha256Hex(canonical),
            approvalState: .awaitingApproval
        )
    }
}
