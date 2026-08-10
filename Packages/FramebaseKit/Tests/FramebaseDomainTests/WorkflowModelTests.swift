import Foundation
import FramebaseDomain
import Testing

@Suite("Durable workflow contracts")
struct WorkflowModelTests {
    private let assetID = AssetID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)

    @Test("Workflow definitions reject unsupported or destructive actions")
    func definitionValidation() {
        #expect(throws: WorkflowValidationError.self) {
            try WorkflowDefinition(
                name: "Unsafe workflow",
                trigger: .manualSelection,
                actions: [.permanentPurge]
            )
        }
    }

    @Test("Planning is deterministic and produces proposal-only output")
    func deterministicProposalPlanning() throws {
        let definition = try WorkflowDefinition(
            id: UUID(uuidString: "12345678-1234-1234-1234-1234567890AC")!,
            name: "Review selected photos",
            trigger: .manualSelection,
            actions: [.runLocalAnalysis, .proposeTag("review:strong")]
        )
        let snapshot = try WorkflowInputSnapshot(
            assetIDs: [assetID],
            catalogRevision: 42,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let first = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)
        let second = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)

        #expect(first == second)
        #expect(first.approvalState == .awaitingApproval)
        #expect(first.steps.allSatisfy { !$0.allowsDirectCatalogMutation })
        #expect(first.idempotencyKey == second.idempotencyKey)

        let changedDefinition = try WorkflowDefinition(
            id: definition.id,
            name: definition.name,
            trigger: definition.trigger,
            actions: [.runLocalAnalysis, .proposeTag("review:needs-review")]
        )
        let changed = try WorkflowPlanner().plan(definition: changedDefinition, snapshot: snapshot)
        #expect(changed.idempotencyKey != first.idempotencyKey)
    }

    @Test("Applying a plan detects snapshot drift")
    func snapshotDriftPreventsApply() throws {
        let plan = try WorkflowPlanner().plan(
            definition: try WorkflowDefinition(name: "Review", trigger: .manualSelection, actions: [.runLocalAnalysis]),
            snapshot: try WorkflowInputSnapshot(assetIDs: [assetID], catalogRevision: 42, capturedAt: .distantPast)
        )

        #expect(throws: WorkflowValidationError.snapshotDrift) {
            try plan.validateForApply(currentCatalogRevision: 43)
        }

        let changed = try WorkflowInputSnapshot(
            assetIDs: [assetID],
            catalogRevision: 42,
            sourceFingerprint: String(repeating: "a", count: 64),
            capturedAt: .distantPast
        )
        #expect(throws: WorkflowValidationError.snapshotDrift) {
            try plan.validateForApply(currentSnapshot: changed)
        }
    }
}
