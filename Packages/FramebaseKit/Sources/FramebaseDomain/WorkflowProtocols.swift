import Foundation

/// Persistence for reviewable workflow state. Implementations must treat the
/// idempotency key as the durable duplicate-delivery boundary.
public protocol WorkflowRepository: Sendable {
    func store(_ definition: WorkflowDefinition, at date: Date) async throws
    func definitions() async throws -> [WorkflowDefinition]
    func enqueue(plan: WorkflowPlan, actor: WorkflowAuditActor, at date: Date) async throws -> WorkflowRun
    func proposal(for workflowRunID: UUID) async throws -> WorkflowProposal?
    func auditEvents(for workflowRunID: UUID) async throws -> [WorkflowAuditEvent]
}
