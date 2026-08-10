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

    public func approve(
        workflowRunID: UUID,
        currentSnapshot: WorkflowInputSnapshot,
        actor: WorkflowAuditActor,
        at date: Date = Date()
    ) async throws -> WorkflowRun {
        try await databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM workflow_runs WHERE id = ?", arguments: [workflowRunID.uuidString.lowercased()]) else {
                throw CatalogError.invalidPersistedValue("workflow_run")
            }
            let plan: WorkflowPlan = try Self.decode(row["plan_json"] as String)
            try plan.validateForApply(currentSnapshot: currentSnapshot)
            guard WorkflowRunState(rawValue: row["state"] as String) == .awaitingApproval else {
                throw CatalogError.invalidPersistedValue("workflow_run_state")
            }
            let milliseconds = CatalogDate.milliseconds(date)
            try db.execute(sql: "UPDATE workflow_runs SET state = ?, updated_at_ms = ? WHERE id = ?", arguments: [
                WorkflowRunState.queued.rawValue, milliseconds, workflowRunID.uuidString.lowercased()
            ])
            try db.execute(sql: "UPDATE workflow_proposals SET state = ? WHERE workflow_run_id = ?", arguments: [
                WorkflowApprovalState.approved.rawValue, workflowRunID.uuidString.lowercased()
            ])
            try Self.insertAudit(.init(workflowRunID: workflowRunID, kind: .approvalGranted, actor: actor, summary: "Exact snapshot approved", capturedAt: date), in: db)
            guard let approved = try Row.fetchOne(db, sql: "SELECT * FROM workflow_runs WHERE id = ?", arguments: [workflowRunID.uuidString.lowercased()]) else {
                throw CatalogError.invalidPersistedValue("workflow_run")
            }
            return try Self.workflowRun(from: approved)
        }
    }

    public func workflowRun(id: UUID) async throws -> WorkflowRun? {
        try await databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM workflow_runs WHERE id = ?", arguments: [id.uuidString.lowercased()]) else {
                return nil
            }
            return try Self.workflowRun(from: row)
        }
    }

    /// Applies only catalog-native, reversible actions after an exact human
    /// approval. The entire action group is one database write: a failure
    /// rolls every catalog change back before a separate failure audit is
    /// recorded. Media analysis remains an AppContainer concern.
    public func executeApproved(
        workflowRunID: UUID,
        currentSnapshot: WorkflowInputSnapshot,
        actor: WorkflowAuditActor,
        at date: Date = Date()
    ) async throws -> WorkflowRun {
        do {
            return try await databasePool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM workflow_runs WHERE id = ?", arguments: [workflowRunID.uuidString.lowercased()]) else {
                    throw CatalogError.invalidPersistedValue("workflow_run")
                }
                let plan: WorkflowPlan = try Self.decode(row["plan_json"] as String)
                try plan.validateForApply(currentSnapshot: currentSnapshot)
                let currentState = WorkflowRunState(rawValue: row["state"] as String)
                if currentState == .succeeded {
                    return try Self.workflowRun(from: row)
                }
                guard currentState == .queued else { throw WorkflowExecutionError.approvalRequired }
                guard try Self.cloudExecutionIsAllowed(in: db) else {
                    throw CatalogError.invalidPersistedValue("workflow_cloud_sync")
                }

                try db.execute(sql: "UPDATE workflow_runs SET state = ?, updated_at_ms = ? WHERE id = ?", arguments: [
                    WorkflowRunState.running.rawValue, CatalogDate.milliseconds(date), workflowRunID.uuidString.lowercased()
                ])
                try Self.insertAudit(.init(workflowRunID: workflowRunID, kind: .executionStarted, actor: actor, summary: "Approved local execution started", capturedAt: date), in: db)
                for step in plan.steps {
                    try Self.execute(step: step, in: db, at: date)
                    try db.execute(sql: "UPDATE workflow_step_runs SET state = ? WHERE workflow_run_id = ? AND sequence = ?", arguments: [
                        WorkflowRunState.succeeded.rawValue, workflowRunID.uuidString.lowercased(), step.sequence
                    ])
                }
                try db.execute(sql: "UPDATE workflow_runs SET state = ?, updated_at_ms = ? WHERE id = ?", arguments: [
                    WorkflowRunState.succeeded.rawValue, CatalogDate.milliseconds(date), workflowRunID.uuidString.lowercased()
                ])
                try Self.insertAudit(.init(workflowRunID: workflowRunID, kind: .executionSucceeded, actor: actor, summary: "Approved local execution completed", capturedAt: date), in: db)
                guard let completed = try Row.fetchOne(db, sql: "SELECT * FROM workflow_runs WHERE id = ?", arguments: [workflowRunID.uuidString.lowercased()]) else {
                    throw CatalogError.invalidPersistedValue("workflow_run")
                }
                return try Self.workflowRun(from: completed)
            }
        } catch let error as WorkflowValidationError where error == .snapshotDrift {
            try await markStale(workflowRunID: workflowRunID, actor: actor, at: date)
            throw error
        } catch {
            try? await markFailed(workflowRunID: workflowRunID, actor: actor, at: date)
            throw error
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

    private func markStale(workflowRunID: UUID, actor: WorkflowAuditActor, at date: Date) async throws {
        try await databasePool.write { db in
            try db.execute(sql: "UPDATE workflow_runs SET state = ?, updated_at_ms = ? WHERE id = ? AND state IN (?, ?)", arguments: [
                WorkflowRunState.stale.rawValue, CatalogDate.milliseconds(date), workflowRunID.uuidString.lowercased(),
                WorkflowRunState.awaitingApproval.rawValue, WorkflowRunState.queued.rawValue
            ])
            try db.execute(sql: "UPDATE workflow_proposals SET state = ? WHERE workflow_run_id = ?", arguments: [
                WorkflowApprovalState.stale.rawValue, workflowRunID.uuidString.lowercased()
            ])
            try Self.insertAudit(.init(workflowRunID: workflowRunID, kind: .snapshotMarkedStale, actor: actor, summary: "Catalog state changed; a new preview is required", capturedAt: date), in: db)
        }
    }

    private func markFailed(workflowRunID: UUID, actor: WorkflowAuditActor, at date: Date) async throws {
        try await databasePool.write { db in
            try db.execute(sql: "UPDATE workflow_runs SET state = ?, updated_at_ms = ? WHERE id = ? AND state = ?", arguments: [
                WorkflowRunState.failed.rawValue, CatalogDate.milliseconds(date), workflowRunID.uuidString.lowercased(), WorkflowRunState.queued.rawValue
            ])
            try db.execute(sql: "UPDATE workflow_step_runs SET state = ? WHERE workflow_run_id = ? AND state = ?", arguments: [
                WorkflowRunState.failed.rawValue, workflowRunID.uuidString.lowercased(), WorkflowRunState.awaitingApproval.rawValue
            ])
            try Self.insertAudit(.init(workflowRunID: workflowRunID, kind: .executionFailed, actor: actor, summary: "Execution failed before catalog changes were committed", capturedAt: date), in: db)
        }
    }

    private static func cloudExecutionIsAllowed(in db: Database) throws -> Bool {
        let mode: String? = try String.fetchOne(db, sql: "SELECT mode FROM sync_state WHERE key = 'library'")
        return mode == nil || mode == "localOnly" || mode == "paused" || mode == "failed"
    }

    private static func execute(step: WorkflowPlanStep, in db: Database, at date: Date) throws {
        switch step.action {
        case let .proposeTag(rawTag):
            let tagName = try TagName(rawTag)
            let milliseconds = CatalogDate.milliseconds(date)
            try db.execute(sql: """
                INSERT INTO tags (id, namespace, value, name, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(name) DO NOTHING
                """, arguments: [
                    TagID().description, tagName.namespace, tagName.value, tagName.rawValue, milliseconds, milliseconds
                ])
            guard let tagID = try String.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ? COLLATE NOCASE", arguments: [tagName.rawValue]) else {
                throw CatalogError.invalidPersistedValue("workflow_tag")
            }
            for assetID in step.targetAssetIDs {
                try db.execute(sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id, added_at_ms) VALUES (?, ?, ?)", arguments: [
                    assetID.description, tagID, milliseconds
                ])
            }
        case let .proposeAddToAlbum(albumID):
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM albums WHERE id = ?)", arguments: [albumID.description]) ?? false
            guard exists else { throw CatalogError.albumNotFound(albumID) }
            var nextSortOrder: Int64 = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), 0) FROM album_assets WHERE album_id = ?", arguments: [albumID.description]) ?? 0
            for assetID in step.targetAssetIDs {
                nextSortOrder += CatalogSortOrder.gap
                try db.execute(sql: "INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at_ms, sort_order) VALUES (?, ?, ?, ?)", arguments: [
                    albumID.description, assetID.description, CatalogDate.milliseconds(date), nextSortOrder
                ])
            }
        case .createProposal, .notifyInApp:
            break
        case .runLocalAnalysis:
            throw WorkflowExecutionError.appServiceRequired
        case .permanentPurge:
            throw WorkflowValidationError.permanentPurgeForbidden
        }
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
