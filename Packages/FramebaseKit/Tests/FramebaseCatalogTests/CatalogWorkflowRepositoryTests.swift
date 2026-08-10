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

    @Test("Approval rejects a changed selected-asset snapshot without changing the proposal")
    func approvalDetectsCatalogDrift() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let definition = try WorkflowDefinition(name: "Review", trigger: .manualSelection, actions: [.runLocalAnalysis])
        let snapshot = try await database.workflowInputSnapshot(assetIDs: [asset.id], capturedAt: .distantPast)
        let plan = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)
        try await database.workflows.store(definition, at: .distantPast)
        let run = try await database.workflows.enqueue(plan: plan, actor: .human, at: .distantPast)

        try await database.assets.updateRating(try AssetRating(5), for: [asset.id])
        let changed = try await database.workflowInputSnapshot(assetIDs: [asset.id], capturedAt: .now)
        do {
            _ = try await database.workflows.approve(workflowRunID: run.id, currentSnapshot: changed, actor: .human, at: .now)
            Issue.record("Expected approval to reject snapshot drift")
        } catch let error as WorkflowValidationError {
            #expect(error == .snapshotDrift)
        } catch {
            throw error
        }
        #expect(try await database.workflows.workflowRun(id: run.id)?.state == .awaitingApproval)
        #expect(try await database.workflows.proposal(for: run.id)?.state == .awaitingApproval)
    }

    @Test("Exact snapshot approval advances only the workflow state and audit history")
    func approvalPreservesCatalogUntilExecution() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let definition = try WorkflowDefinition(name: "Review", trigger: .manualSelection, actions: [.runLocalAnalysis])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await database.workflowInputSnapshot(assetIDs: [asset.id], capturedAt: date)
        let plan = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)
        try await database.workflows.store(definition, at: date)
        let run = try await database.workflows.enqueue(plan: plan, actor: .human, at: date)

        let approved = try await database.workflows.approve(workflowRunID: run.id, currentSnapshot: snapshot, actor: .human, at: date.addingTimeInterval(1))
        #expect(approved.state == .queued)
        #expect(try await database.workflows.proposal(for: run.id)?.state == .approved)
        #expect(try await database.workflows.auditEvents(for: run.id).map(\.kind) == [.planCreated, .proposalCreated, .approvalGranted])
        let unchangedAsset = try #require(await database.assets.asset(id: asset.id))
        #expect(unchangedAsset.parentFolderID == asset.parentFolderID)
        #expect(unchangedAsset.displayName == asset.displayName)
        #expect(unchangedAsset.favorite == asset.favorite)
        #expect(unchangedAsset.rating == asset.rating)
    }

    @Test("Approved tag action commits once and replays without duplicate organization")
    func approvedTagActionIsAtomicAndIdempotent() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let definition = try WorkflowDefinition(name: "Mark review", trigger: .manualSelection, actions: [.proposeTag("review:strong")])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await database.workflowInputSnapshot(assetIDs: [asset.id], capturedAt: date)
        let plan = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)
        try await database.workflows.store(definition, at: date)
        let run = try await database.workflows.enqueue(plan: plan, actor: .human, at: date)
        _ = try await database.workflows.approve(workflowRunID: run.id, currentSnapshot: snapshot, actor: .human, at: date)

        let completed = try await database.workflows.executeApproved(workflowRunID: run.id, currentSnapshot: snapshot, actor: .human, at: date.addingTimeInterval(1))
        let replay = try await database.workflows.executeApproved(workflowRunID: run.id, currentSnapshot: snapshot, actor: .human, at: date.addingTimeInterval(2))
        #expect(completed == replay)
        #expect(completed.state == .succeeded)
        #expect(try await database.tags.tags(for: [asset.id])[asset.id]?.map(\.name.rawValue) == ["review:strong"])
        #expect(try await database.workflows.auditEvents(for: run.id).map(\.kind) == [.planCreated, .proposalCreated, .approvalGranted, .executionStarted, .executionSucceeded])
    }

    @Test("Undo removes only memberships created by the completed workflow")
    func undoPreservesPreexistingTagMembership() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let addedByWorkflow = try makeAsset(parentFolderID: database.inboxID)
        let alreadyTagged = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(addedByWorkflow)
        try await database.insertAsset(alreadyTagged)
        let tag = try await database.tags.createTag(named: TagName("review:strong"))
        try await database.tags.addTags([tag.id], to: [alreadyTagged.id])

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let definition = try WorkflowDefinition(name: "Mark review", trigger: .manualSelection, actions: [.proposeTag("review:strong")])
        let snapshot = try await database.workflowInputSnapshot(assetIDs: [addedByWorkflow.id, alreadyTagged.id], capturedAt: date)
        let plan = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)
        try await database.workflows.store(definition, at: date)
        let run = try await database.workflows.enqueue(plan: plan, actor: .human, at: date)
        _ = try await database.workflows.approve(workflowRunID: run.id, currentSnapshot: snapshot, actor: .human, at: date)
        _ = try await database.workflows.executeApproved(workflowRunID: run.id, currentSnapshot: snapshot, actor: .human, at: date.addingTimeInterval(1))

        #expect(try await database.workflows.undo(workflowRunID: run.id, actor: .human, at: date.addingTimeInterval(2)))
        let tagsByAsset = try await database.tags.tags(for: [addedByWorkflow.id, alreadyTagged.id])
        #expect(tagsByAsset[addedByWorkflow.id] == nil)
        #expect(tagsByAsset[alreadyTagged.id]?.map(\.name.rawValue) == ["review:strong"])
        #expect(!(try await database.workflows.undo(workflowRunID: run.id, actor: .human, at: date.addingTimeInterval(3))))
        #expect(try await database.workflows.auditEvents(for: run.id).map(\.kind) == [.planCreated, .proposalCreated, .approvalGranted, .executionStarted, .executionSucceeded, .undoStarted, .undoSucceeded])
    }

    @Test("A later failed workflow step rolls back every earlier catalog action")
    func failedWorkflowExecutionIsAtomic() async throws {
        let temporary = try TemporaryCatalog()
        let database = temporary.database
        let asset = try makeAsset(parentFolderID: database.inboxID)
        try await database.insertAsset(asset)
        let definition = try WorkflowDefinition(
            name: "Atomic review",
            trigger: .manualSelection,
            actions: [.proposeTag("review:strong"), .proposeAddToAlbum(AlbumID())]
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await database.workflowInputSnapshot(assetIDs: [asset.id], capturedAt: date)
        let plan = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)
        try await database.workflows.store(definition, at: date)
        let run = try await database.workflows.enqueue(plan: plan, actor: .human, at: date)
        _ = try await database.workflows.approve(workflowRunID: run.id, currentSnapshot: snapshot, actor: .human, at: date)

        do {
            _ = try await database.workflows.executeApproved(workflowRunID: run.id, currentSnapshot: snapshot, actor: .human, at: date.addingTimeInterval(1))
            Issue.record("Expected execution to reject an unknown album")
        } catch let error as CatalogError {
            guard case .albumNotFound = error else { throw error }
        }
        #expect(try await database.tags.tags(for: [asset.id])[asset.id] == nil)
        #expect(try await database.workflows.workflowRun(id: run.id)?.state == .failed)
        #expect(try await database.workflows.auditEvents(for: run.id).map(\.kind) == [.planCreated, .proposalCreated, .approvalGranted, .executionFailed])
    }
}
