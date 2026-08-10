import Foundation
import FramebaseCatalog
import FramebaseDomain
import FramebaseTestSupport
import Testing

@Suite("Catalog workflow repository", .serialized)
struct CatalogWorkflowRepositoryTests {
    @Test("Workflow plans persist idempotently with a proposal and append-only audit after reopen")
    func workflowPlanHistoryReopensSafely() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)

        let definition = try WorkflowDefinition(
            id: UUID(uuidString: "12345678-1234-1234-1234-1234567890AC")!,
            name: "Review selected photos",
            trigger: .manualSelection,
            actions: [.runLocalAnalysis, .proposeTag("review:strong")]
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = try WorkflowPlanner().plan(
            definition: definition,
            snapshot: try WorkflowInputSnapshot(assetIDs: [asset.id], catalogRevision: 42, capturedAt: date)
        )

        try await database.workflows.store(definition, at: date)
        let first = try await database.workflows.enqueue(plan: plan, actor: .human, at: date)
        let duplicate = try await database.workflows.enqueue(plan: plan, actor: .human, at: date.addingTimeInterval(60))
        #expect(first == duplicate)

        let reopened = try CatalogDatabase(catalogURL: temporary.databaseURL)
        #expect(try await reopened.workflows.definitions() == [definition])
        let proposal = try #require(await reopened.workflows.proposal(for: first.id))
        #expect(proposal.plan == plan)
        #expect(proposal.state == .awaitingApproval)
        #expect(proposal.createdAt == date)
        let audit = try await reopened.workflows.auditEvents(for: first.id)
        #expect(audit.map(\.kind) == [.planCreated, .proposalCreated])
        #expect(audit.allSatisfy { $0.actor == .human })
    }
}
