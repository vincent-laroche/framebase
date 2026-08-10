import Foundation

/// Persistence for reviewable workflow state. Implementations must treat the
/// idempotency key as the durable duplicate-delivery boundary.
public protocol WorkflowRepository: Sendable {
    func store(_ definition: WorkflowDefinition, at date: Date) async throws
    func definitions() async throws -> [WorkflowDefinition]
    func enqueue(plan: WorkflowPlan, actor: WorkflowAuditActor, actorIdentityID: UUID?, originatingTool: String?, at date: Date) async throws -> WorkflowRun
    func approve(workflowRunID: UUID, currentSnapshot: WorkflowInputSnapshot, actor: WorkflowAuditActor, actorIdentityID: UUID?, originatingTool: String?, at date: Date) async throws -> WorkflowRun
    func executeApproved(workflowRunID: UUID, currentSnapshot: WorkflowInputSnapshot, actor: WorkflowAuditActor, actorIdentityID: UUID?, originatingTool: String?, at date: Date) async throws -> WorkflowRun
    /// Reverts only exact catalog effects stored by a completed workflow run.
    /// Calling undo again is idempotent and returns `false`.
    func undo(workflowRunID: UUID, actor: WorkflowAuditActor, actorIdentityID: UUID?, originatingTool: String?, at date: Date) async throws -> Bool
    func workflowRun(id: UUID) async throws -> WorkflowRun?
    func proposal(for workflowRunID: UUID) async throws -> WorkflowProposal?
    func auditEvents(for workflowRunID: UUID) async throws -> [WorkflowAuditEvent]
}
