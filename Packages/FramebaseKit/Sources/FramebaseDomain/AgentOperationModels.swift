import Foundation

public enum AgentOperationValidationError: Error, Equatable, Sendable {
    case invalidCatalogRevision
    case expiredApproval
    case invalidIdentityName
    case emptyIdentityScopes
}

public enum AgentScope: String, Codable, CaseIterable, Hashable, Sendable {
    case libraryRead = "library.read"
    case assetsMetadataWrite = "assets.metadata.write"
    case assetsOrganize = "assets.organize"
    case intelligenceRun = "intelligence.run"
    case workflowsRun = "workflows.run"
    case exportsRead = "exports.read"
}

public enum AgentIdentityStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case revoked
}

/// An identity contains only its public ID, display name, and delegated scopes.
/// Credential material is deliberately outside Framebase domain models.
public struct AgentIdentity: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let scopes: Set<AgentScope>
    public let status: AgentIdentityStatus

    public init(id: UUID = UUID(), name: String, scopes: Set<AgentScope>, status: AgentIdentityStatus = .active) {
        self.id = id
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = normalizedName.isEmpty ? "Unnamed local agent" : String(normalizedName.prefix(120))
        self.scopes = scopes
        self.status = status
    }

    public var isActive: Bool { status == .active }
}

/// A local catalog registry for explicitly delegated agent principals. It
/// stores no credential material; remote authentication remains a separate
/// adapter concern.
public protocol AgentIdentityRepository: Sendable {
    func create(_ identity: AgentIdentity, at date: Date) async throws
    func identity(id: UUID) async throws -> AgentIdentity?
    func revoke(id: UUID, at date: Date) async throws
}

public enum AgentOperationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case searchAssets
    case getAsset
    case getMetadata
    case listFolders
    case createFolder
    case moveAssets
    case renameAsset
    case setRating
    case addTags
    case addToAlbum
    case runOCR
    case analyzeAssets
    case runWorkflow
    case getOperation
    case downloadOriginal
    case exportAssets
    case diagnostics
}

public enum AgentOperationParameters: Codable, Hashable, Sendable {
    case none
    case searchText(String)
    case folderID(FolderID)
    case tagName(String)
    case albumID(AlbumID)
}

public enum AgentOperationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case awaitingApproval
    case running
    case succeeded
    case failed
    case denied
    case cancelled
}

/// A request is a scope-checked proposal to use a supported capability, never a
/// raw database or storage operation.
public struct AgentOperationRequest: Codable, Hashable, Sendable, CustomStringConvertible {
    public let id: UUID
    public let operation: AgentOperationKind
    public let targetAssetIDs: [AssetID]
    public let catalogRevision: Int64
    public let parameters: AgentOperationParameters

    public init(
        id: UUID = UUID(),
        operation: AgentOperationKind,
        targetAssetIDs: [AssetID],
        catalogRevision: Int64,
        parameters: AgentOperationParameters = .none
    ) throws {
        guard catalogRevision >= 0 else { throw AgentOperationValidationError.invalidCatalogRevision }
        self.id = id
        self.operation = operation
        self.targetAssetIDs = Array(Set(targetAssetIDs)).sorted { $0.description < $1.description }
        self.catalogRevision = catalogRevision
        self.parameters = parameters
    }

    public var requiredScope: AgentScope {
        switch operation {
        case .searchAssets, .getAsset, .getMetadata, .listFolders, .getOperation, .diagnostics:
            .libraryRead
        case .createFolder, .moveAssets, .renameAsset, .addTags, .addToAlbum:
            .assetsOrganize
        case .setRating:
            .assetsMetadataWrite
        case .runOCR, .analyzeAssets:
            .intelligenceRun
        case .runWorkflow:
            .workflowsRun
        case .downloadOriginal, .exportAssets:
            .exportsRead
        }
    }

    public var requiresProposal: Bool {
        switch operation {
        case .createFolder, .moveAssets, .renameAsset, .setRating, .addTags, .addToAlbum, .exportAssets:
            true
        default:
            false
        }
    }

    public func canApply(as identity: AgentIdentity, approval: AgentApprovalToken?, at date: Date) -> Bool {
        guard identity.isActive, identity.scopes.contains(requiredScope) else { return false }
        guard requiresProposal else { return true }
        return approval?.matches(self, at: date) == true
    }

    public var description: String {
        "AgentOperationRequest(operation: \(operation.rawValue), targetCount: \(targetAssetIDs.count), catalogRevision: \(catalogRevision), parameters: <redacted>)"
    }
}

/// An approval binds to an exact request, target set, and catalog revision. A
/// remote adapter must sign or otherwise authenticate this value before use.
public struct AgentApprovalToken: Codable, Hashable, Sendable {
    public let id: UUID
    public let operationID: UUID
    public let targetAssetIDs: [AssetID]
    public let catalogRevision: Int64
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        operationID: UUID,
        targetAssetIDs: [AssetID],
        catalogRevision: Int64,
        expiresAt: Date
    ) throws {
        guard catalogRevision >= 0 else { throw AgentOperationValidationError.invalidCatalogRevision }
        self.id = id
        self.operationID = operationID
        self.targetAssetIDs = Array(Set(targetAssetIDs)).sorted { $0.description < $1.description }
        self.catalogRevision = catalogRevision
        self.expiresAt = expiresAt
    }

    public func matches(_ request: AgentOperationRequest, at date: Date) -> Bool {
        date <= expiresAt && operationID == request.id && targetAssetIDs == request.targetAssetIDs && catalogRevision == request.catalogRevision
    }
}
