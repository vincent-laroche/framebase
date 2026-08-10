import Foundation
import FramebaseDomain
import GRDB

public struct CatalogWorkflowRepository: WorkflowRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) { self.databasePool = databasePool }

    public func store(_ definition: WorkflowDefinition, at date: Date = Date()) async throws {
        let definitionJSON = try Self.encode(definition)
        let milliseconds = CatalogDate.milliseconds(date)
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO workflow_definitions (id, schema_version, definition_json, is_enabled, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [
                    definition.id.uuidString.lowercased(), definition.schemaVersion, definitionJSON,
                    definition.isEnabled, milliseconds, milliseconds
                ])
        }
    }

    public func definitions() async throws -> [WorkflowDefinition] {
        try await databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT definition_json FROM workflow_definitions ORDER BY created_at_ms ASC, id ASC")
                .map(Self.decode)
        }
    }

    public func enqueue(plan: WorkflowPlan, actor: WorkflowAuditActor, at date: Date = Date()) async throws -> WorkflowRun {
        let planJSON = try Self.encode(plan)
        let milliseconds = CatalogDate.milliseconds(date)
        return try await databasePool.write { db in
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM workflow_runs WHERE idempotency_key = ?", arguments: [plan.idempotencyKey]) {
                return try Self.workflowRun(from: existing)
            }

            let run = WorkflowRun(
                definitionID: plan.definitionID,
                idempotencyKey: plan.idempotencyKey,
                state: .awaitingApproval,
                snapshotCatalogRevision: plan.snapshot.catalogRevision,
                createdAt: date,
                updatedAt: date
            )
            try db.execute(sql: """
                INSERT INTO workflow_runs (id, definition_id, idempotency_key, state, snapshot_catalog_revision, plan_json, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    run.id.uuidString.lowercased(), run.definitionID.uuidString.lowercased(), run.idempotencyKey,
                    run.state.rawValue, run.snapshotCatalogRevision, planJSON, milliseconds, milliseconds
                ])
            for step in plan.steps {
                let stepRun = WorkflowStepRun(
                    workflowRunID: run.id,
                    sequence: step.sequence,
                    action: step.action,
                    targetAssetIDs: step.targetAssetIDs,
                    state: .awaitingApproval
                )
                try db.execute(sql: """
                    INSERT INTO workflow_step_runs (id, workflow_run_id, sequence, action_json, target_asset_ids_json, state)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        stepRun.id.uuidString.lowercased(), run.id.uuidString.lowercased(), stepRun.sequence,
                        try Self.encode(stepRun.action), try Self.encode(stepRun.targetAssetIDs), stepRun.state.rawValue
                    ])
            }
            let proposal = WorkflowProposal(plan: plan, createdAt: date)
            try db.execute(sql: """
                INSERT INTO workflow_proposals (id, workflow_run_id, plan_json, state, created_at_ms)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    proposal.id.uuidString.lowercased(), run.id.uuidString.lowercased(), planJSON,
                    proposal.state.rawValue, milliseconds
                ])
            try Self.insertAudit(.init(workflowRunID: run.id, kind: .planCreated, actor: actor, summary: "Dry-run plan created", capturedAt: date), in: db)
            try Self.insertAudit(.init(workflowRunID: run.id, kind: .proposalCreated, actor: actor, summary: "Proposal awaiting exact approval", capturedAt: date), in: db)
            return run
        }
    }

    public func proposal(for workflowRunID: UUID) async throws -> WorkflowProposal? {
        try await databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM workflow_proposals WHERE workflow_run_id = ?", arguments: [workflowRunID.uuidString.lowercased()]) else {
                return nil
            }
            return try WorkflowProposal(
                id: UUID(uuidString: row["id"] as String)!,
                plan: Self.decode(row["plan_json"] as String),
                state: WorkflowApprovalState(rawValue: row["state"] as String)!,
                createdAt: CatalogDate.date(row["created_at_ms"] as Int64)
            )
        }
    }

    public func auditEvents(for workflowRunID: UUID) async throws -> [WorkflowAuditEvent] {
        try await databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM workflow_audit_events WHERE workflow_run_id = ? ORDER BY rowid ASC", arguments: [workflowRunID.uuidString.lowercased()]).map { row in
                WorkflowAuditEvent(
                    id: UUID(uuidString: row["id"] as String)!,
                    workflowRunID: workflowRunID,
                    kind: WorkflowAuditEventKind(rawValue: row["kind"] as String)!,
                    actor: WorkflowAuditActor(rawValue: row["actor"] as String)!,
                    summary: row["summary"],
                    capturedAt: CatalogDate.date(row["captured_at_ms"] as Int64)
                )
            }
        }
    }

    private static func insertAudit(_ event: WorkflowAuditEvent, in db: Database) throws {
        try db.execute(sql: "INSERT INTO workflow_audit_events (id, workflow_run_id, kind, actor, summary, captured_at_ms) VALUES (?, ?, ?, ?, ?, ?)", arguments: [
            event.id.uuidString.lowercased(), event.workflowRunID.uuidString.lowercased(), event.kind.rawValue,
            event.actor.rawValue, event.summary, CatalogDate.milliseconds(event.capturedAt)
        ])
    }

    private static func workflowRun(from row: Row) throws -> WorkflowRun {
        WorkflowRun(
            id: UUID(uuidString: row["id"] as String)!,
            definitionID: UUID(uuidString: row["definition_id"] as String)!,
            idempotencyKey: row["idempotency_key"],
            state: WorkflowRunState(rawValue: row["state"] as String)!,
            snapshotCatalogRevision: row["snapshot_catalog_revision"],
            createdAt: CatalogDate.date(row["created_at_ms"] as Int64),
            updatedAt: CatalogDate.date(row["updated_at_ms"] as Int64)
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<Value: Decodable>(_ value: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(value.utf8))
    }
}
