import CryptoKit
import Foundation

public enum WorkflowValidationError: Error, Equatable, Sendable {
    case invalidDefinitionName
    case unsupportedSchemaVersion
    case emptyActions
    case permanentPurgeForbidden
    case invalidTagName
    case emptyInputSelection
    case invalidCatalogRevision
    case snapshotDrift
    case invalidSnapshotFingerprint
}

public enum WorkflowExecutionError: Error, Equatable, Sendable {
    case approvalRequired
    case appServiceRequired
    case undoUnavailable
}

public enum WorkflowTrigger: String, Codable, CaseIterable, Hashable, Sendable {
    case manualSelection
    case importCompleted
    case metadataChanged
    case folderEntry
    case schedule
}

/// Workflow actions describe intent. Planning converts them into reviewable
/// steps; no action object has catalog, SQL, or file-mutation authority.
public enum WorkflowAction: Codable, Hashable, Sendable {
    case runLocalAnalysis
    case proposeTag(String)
    case proposeAddToAlbum(AlbumID)
    case createProposal
    case notifyInApp(String)
    case permanentPurge

    /// A stable, versioned representation used for idempotency. Never derive
    /// durable keys from Swift's debug descriptions.
    public var canonicalValue: String {
        switch self {
        case .runLocalAnalysis:
            "runLocalAnalysis"
        case let .proposeTag(tag):
            "proposeTag:" + tag
        case let .proposeAddToAlbum(albumID):
            "proposeAddToAlbum:" + albumID.description
        case .createProposal:
            "createProposal"
        case let .notifyInApp(message):
            "notifyInApp:" + message
        case .permanentPurge:
            "permanentPurge"
        }
    }
}

public struct WorkflowDefinition: Codable, Hashable, Sendable {
    public static let supportedSchemaVersion = 1

    public let id: UUID
    public let schemaVersion: Int
    public let name: String
    public let trigger: WorkflowTrigger
    public let actions: [WorkflowAction]
    public let isEnabled: Bool

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = supportedSchemaVersion,
        name: String,
        trigger: WorkflowTrigger,
        actions: [WorkflowAction],
        isEnabled: Bool = true
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw WorkflowValidationError.invalidDefinitionName }
        guard schemaVersion == Self.supportedSchemaVersion else { throw WorkflowValidationError.unsupportedSchemaVersion }
        guard !actions.isEmpty else { throw WorkflowValidationError.emptyActions }
        for action in actions {
            switch action {
            case .permanentPurge:
                throw WorkflowValidationError.permanentPurgeForbidden
            case let .proposeTag(tag):
                guard (try? TagName(tag)) != nil else {
                    throw WorkflowValidationError.invalidTagName
                }
            default:
                break
            }
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = normalizedName
        self.trigger = trigger
        self.actions = actions
        self.isEnabled = isEnabled
    }
}

public struct WorkflowInputSnapshot: Codable, Hashable, Sendable {
    public let assetIDs: [AssetID]
    public let catalogRevision: Int64
    /// Digest of the selected assets' logical state, tags, and album
    /// membership. This protects a plan when the catalog has no single global
    /// revision counter covering every local relationship.
    public let sourceFingerprint: String
    public let capturedAt: Date

    public init(
        assetIDs: [AssetID],
        catalogRevision: Int64,
        sourceFingerprint: String? = nil,
        capturedAt: Date
    ) throws {
        guard !assetIDs.isEmpty else { throw WorkflowValidationError.emptyInputSelection }
        guard catalogRevision >= 0 else { throw WorkflowValidationError.invalidCatalogRevision }
        let normalizedAssetIDs = Array(Set(assetIDs)).sorted { $0.description < $1.description }
        let fallbackFingerprint = WorkflowFingerprint.sha256Hex(
            normalizedAssetIDs.map(\.description).joined(separator: ",") + ":" + catalogRevision.description
        )
        let fingerprint = (sourceFingerprint ?? fallbackFingerprint).lowercased()
        guard WorkflowFingerprint.isSHA256(fingerprint) else { throw WorkflowValidationError.invalidSnapshotFingerprint }
        self.assetIDs = normalizedAssetIDs
        self.catalogRevision = catalogRevision
        self.sourceFingerprint = fingerprint
        self.capturedAt = capturedAt
    }
}

public enum WorkflowApprovalState: String, Codable, CaseIterable, Hashable, Sendable {
    case draft
    case awaitingApproval
    case approved
    case rejected
    case stale
}

public enum WorkflowRunState: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case awaitingApproval
    case running
    case succeeded
    case failed
    case cancelled
    case stale
}

public enum WorkflowAuditActor: String, Codable, CaseIterable, Hashable, Sendable {
    case human
    case workflow
    case agent
    case system
}

public enum WorkflowAuditEventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case planCreated
    case proposalCreated
    case approvalGranted
    case approvalRejected
    case executionStarted
    case executionSucceeded
    case executionFailed
    case undoStarted
    case undoSucceeded
    case runCancelled
    case snapshotMarkedStale
}

public struct WorkflowPlanStep: Codable, Hashable, Sendable {
    public let sequence: Int
    public let action: WorkflowAction
    public let targetAssetIDs: [AssetID]

    public init(sequence: Int, action: WorkflowAction, targetAssetIDs: [AssetID]) {
        self.sequence = sequence
        self.action = action
        self.targetAssetIDs = targetAssetIDs
    }

    public var allowsDirectCatalogMutation: Bool { false }
}

public struct WorkflowPlan: Codable, Hashable, Sendable {
    public let definitionID: UUID
    public let definitionSchemaVersion: Int
    public let snapshot: WorkflowInputSnapshot
    public let steps: [WorkflowPlanStep]
    public let idempotencyKey: String
    public let approvalState: WorkflowApprovalState

    public init(
        definitionID: UUID,
        definitionSchemaVersion: Int,
        snapshot: WorkflowInputSnapshot,
        steps: [WorkflowPlanStep],
        idempotencyKey: String,
        approvalState: WorkflowApprovalState
    ) {
        self.definitionID = definitionID
        self.definitionSchemaVersion = definitionSchemaVersion
        self.snapshot = snapshot
        self.steps = steps
        self.idempotencyKey = idempotencyKey
        self.approvalState = approvalState
    }

    public func validateForApply(currentCatalogRevision: Int64) throws {
        guard currentCatalogRevision == snapshot.catalogRevision else { throw WorkflowValidationError.snapshotDrift }
    }

    public func validateForApply(currentSnapshot: WorkflowInputSnapshot) throws {
        guard currentSnapshot.assetIDs == snapshot.assetIDs,
              currentSnapshot.catalogRevision == snapshot.catalogRevision,
              currentSnapshot.sourceFingerprint == snapshot.sourceFingerprint else {
            throw WorkflowValidationError.snapshotDrift
        }
    }
}

public struct WorkflowProposal: Codable, Hashable, Sendable {
    public let id: UUID
    public let plan: WorkflowPlan
    public let state: WorkflowApprovalState
    public let createdAt: Date

    public init(id: UUID = UUID(), plan: WorkflowPlan, state: WorkflowApprovalState = .awaitingApproval, createdAt: Date) {
        self.id = id
        self.plan = plan
        self.state = state
        self.createdAt = createdAt
    }
}

public struct WorkflowRun: Codable, Hashable, Sendable {
    public let id: UUID
    public let definitionID: UUID
    public let idempotencyKey: String
    public let state: WorkflowRunState
    public let snapshotCatalogRevision: Int64
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        definitionID: UUID,
        idempotencyKey: String,
        state: WorkflowRunState,
        snapshotCatalogRevision: Int64,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.definitionID = definitionID
        self.idempotencyKey = idempotencyKey
        self.state = state
        self.snapshotCatalogRevision = snapshotCatalogRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WorkflowStepRun: Codable, Hashable, Sendable {
    public let id: UUID
    public let workflowRunID: UUID
    public let sequence: Int
    public let action: WorkflowAction
    public let targetAssetIDs: [AssetID]
    public let state: WorkflowRunState
    public let result: WorkflowStepResult?

    public init(
        id: UUID = UUID(),
        workflowRunID: UUID,
        sequence: Int,
        action: WorkflowAction,
        targetAssetIDs: [AssetID],
        state: WorkflowRunState,
        result: WorkflowStepResult? = nil
    ) {
        self.id = id
        self.workflowRunID = workflowRunID
        self.sequence = sequence
        self.action = action
        self.targetAssetIDs = targetAssetIDs
        self.state = state
        self.result = result
    }
}

/// An exact, catalog-only effect of an applied step. It is recorded after the
/// transaction commits so a later undo can remove only membership rows the
/// workflow itself added; it never guesses from the current catalog state.
public enum WorkflowStepResult: Codable, Hashable, Sendable {
    case tagApplication(WorkflowTagApplicationEffect)
}

public struct WorkflowTagApplicationEffect: Codable, Hashable, Sendable {
    public let tagID: TagID
    public let tagName: String
    public let addedAssetIDs: [AssetID]
    public let addedAt: Date
    public let createdTag: Bool

    public init(tagID: TagID, tagName: String, addedAssetIDs: [AssetID], addedAt: Date, createdTag: Bool) {
        self.tagID = tagID
        self.tagName = tagName
        self.addedAssetIDs = Array(Set(addedAssetIDs)).sorted { $0.description < $1.description }
        self.addedAt = addedAt
        self.createdTag = createdTag
    }
}

/// Append-only workflow provenance. Metadata is intentionally constrained to a
/// short, redacted summary rather than request bodies, paths, or media bytes.
public struct WorkflowAuditEvent: Codable, Hashable, Sendable {
    public let id: UUID
    public let workflowRunID: UUID
    public let kind: WorkflowAuditEventKind
    public let actor: WorkflowAuditActor
    public let summary: String
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        workflowRunID: UUID,
        kind: WorkflowAuditEventKind,
        actor: WorkflowAuditActor,
        summary: String,
        capturedAt: Date
    ) {
        self.id = id
        self.workflowRunID = workflowRunID
        self.kind = kind
        self.actor = actor
        self.summary = summary
        self.capturedAt = capturedAt
    }
}

public enum WorkflowFingerprint {
    public static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
