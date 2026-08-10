import Foundation

public enum ProviderItemKind: String, Codable, Sendable {
    case root
    case folder
    case asset
    case trash
}

public enum FileProviderMaterializationState: String, Codable, Sendable {
    case localVerified
    case localOnly
    case remoteOnly
    case unavailable
}

public enum FileProviderCapability: String, Codable, Hashable, Sendable {
    case read
    case createFolder
    case rename
    case move
    case trash
    case materialize
}

public struct FileProviderSyncAnchor: Codable, Hashable, Comparable, Sendable {
    public let sequence: Int64

    public init(sequence: Int64) {
        self.sequence = sequence
    }

    public static func < (lhs: FileProviderSyncAnchor, rhs: FileProviderSyncAnchor) -> Bool {
        lhs.sequence < rhs.sequence
    }
}

public struct FileProviderItemSnapshot: Codable, Hashable, Sendable {
    public let itemID: ProviderItemID
    public let parentItemID: ProviderItemID?
    public let kind: ProviderItemKind
    public let filename: String
    public let contentTypeIdentifier: String?
    public let byteSize: Int64?
    public let modifiedAt: Date
    public let revision: Int64
    public let materializationState: FileProviderMaterializationState
    public let capabilities: Set<FileProviderCapability>

    public init(
        itemID: ProviderItemID,
        parentItemID: ProviderItemID?,
        kind: ProviderItemKind,
        filename: String,
        contentTypeIdentifier: String? = nil,
        byteSize: Int64? = nil,
        modifiedAt: Date,
        revision: Int64,
        materializationState: FileProviderMaterializationState,
        capabilities: Set<FileProviderCapability>
    ) {
        self.itemID = itemID
        self.parentItemID = parentItemID
        self.kind = kind
        self.filename = filename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.revision = revision
        self.materializationState = materializationState
        self.capabilities = capabilities
    }
}

public enum FileProviderMutationProposal: Hashable, Sendable {
    case createFolder(parentItemID: ProviderItemID, name: String)
    case rename(itemID: ProviderItemID, filename: String, baseRevision: Int64)
    case move(itemID: ProviderItemID, parentItemID: ProviderItemID, baseRevision: Int64)
    case trash(itemID: ProviderItemID, baseRevision: Int64)
}
