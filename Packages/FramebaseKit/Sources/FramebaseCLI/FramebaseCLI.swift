import Foundation
import FramebaseCatalog
import FramebaseDomain

public enum FramebaseCLIError: LocalizedError, Equatable, Sendable {
    case missingCommand
    case unsupportedCommand(String)
    case missingCatalogPath
    case missingSearchText
    case missingAssetID
    case missingTagName
    case missingOperationID
    case missingApprovalToken
    case invalidIdentifier(String)
    case invalidApprovalToken
    case assetNotFound
    case unexpectedArgument(String)

    public var errorDescription: String? {
        switch self {
        case .missingCommand: "Choose diagnostics, list-folders, search, inspect, proposal, apply, or get-operation."
        case let .unsupportedCommand(command): "Unsupported command: \(command)."
        case .missingCatalogPath: "Pass --catalog followed by a catalog.sqlite path."
        case .missingSearchText: "Pass --text followed by a search value."
        case .missingAssetID: "Pass one or more --asset values containing UUIDs."
        case .missingTagName: "Pass --tag followed by a namespace:value tag."
        case .missingOperationID: "Pass --operation followed by a proposal UUID."
        case .missingApprovalToken: "Pass --approval followed by the exact opaque token returned by proposal."
        case let .invalidIdentifier(value): "Invalid UUID: \(value)."
        case .invalidApprovalToken: "The approval token is invalid or expired. Create a new proposal."
        case .assetNotFound: "The requested asset does not exist."
        case let .unexpectedArgument(argument): "Unexpected argument: \(argument)."
        }
    }
}

/// Local command surface for catalog inspection and a single, proposal-first
/// organization action. It never exposes managed-original paths, storage keys,
/// cloud credentials, arbitrary SQL, or permanent purge.
public enum FramebaseCLI {
    public static let usage = """
    Usage:
      framebase diagnostics --catalog /path/to/catalog.sqlite
      framebase list-folders --catalog /path/to/catalog.sqlite
      framebase search --catalog /path/to/catalog.sqlite --text "query"
      framebase inspect --catalog /path/to/catalog.sqlite --asset UUID
      framebase proposal tag --catalog /path/to/catalog.sqlite --asset UUID [--asset UUID] --tag namespace:value
      framebase get-operation --catalog /path/to/catalog.sqlite --operation UUID
      framebase apply --catalog /path/to/catalog.sqlite --operation UUID --approval OPAQUE_TOKEN

    Mutations are proposal-first. `proposal tag` changes no organization and
    returns a short-lived opaque approval token; `apply` requires that exact
    token and an unchanged logical snapshot. The CLI never exposes
    managed-original paths, storage keys, cloud credentials, or permanent purge.
    """

    public static func execute(arguments: [String]) async throws -> String {
        if arguments == ["--help"] || arguments == ["help"] { return usage }
        let command = try Command(arguments: arguments)
        let catalog = try CatalogDatabase(catalogURL: command.catalogURL)

        switch command.kind {
        case .diagnostics:
            let folders = try await catalog.folders.treeSnapshot()
            let assets = try await catalog.assets.count(matching: AssetQuery(scope: .allAssets))
            return try encode(DiagnosticsResponse(catalogID: catalog.catalogID.description, schemaVersion: FramebaseCatalogFoundation.currentSchemaVersion, folderCount: folders.folders.count, assetCount: assets))
        case .listFolders:
            return try encode(try await catalog.folders.treeSnapshot().folders.map(FolderResponse.init))
        case let .search(text):
            let page = try await catalog.assets.page(matching: AssetQuery(scope: .allAssets, filter: AssetFilter(text: text)), sortedBy: .defaultSort, offset: 0, limit: 200)
            return try encode(SearchResponse(totalCount: page.totalCount, assets: page.records.map(AssetResponse.init)))
        case let .inspect(assetID):
            guard let asset = try await catalog.assets.asset(id: assetID) else { throw FramebaseCLIError.assetNotFound }
            let tags = try await catalog.tags.tags(for: [assetID])[assetID] ?? []
            return try encode(InspectionResponse(asset: AssetResponse(asset), tagNames: tags.map { $0.name.rawValue }.sorted()))
        case let .proposeTag(assetIDs, tagName):
            return try await proposeTag(assetIDs: assetIDs, tagName: tagName, catalog: catalog)
        case let .getOperation(workflowRunID):
            return try await operationResponse(workflowRunID: workflowRunID, catalog: catalog)
        case let .apply(workflowRunID, approvalToken):
            guard try await catalog.workflows.validateLocalCLIApprovalToken(workflowRunID: workflowRunID, token: approvalToken) else {
                throw FramebaseCLIError.invalidApprovalToken
            }
            guard let proposal = try await catalog.workflows.proposal(for: workflowRunID) else {
                throw FramebaseCLIError.invalidIdentifier(workflowRunID.uuidString)
            }
            let snapshot = try await catalog.workflowInputSnapshot(assetIDs: Set(proposal.plan.snapshot.assetIDs))
            _ = try await catalog.workflows.approve(workflowRunID: workflowRunID, currentSnapshot: snapshot, actor: .agent, at: .now)
            _ = try await catalog.workflows.executeApproved(workflowRunID: workflowRunID, currentSnapshot: snapshot, actor: .agent, at: .now)
            return try await operationResponse(workflowRunID: workflowRunID, catalog: catalog)
        }
    }

    private static func proposeTag(assetIDs: [AssetID], tagName: TagName, catalog: CatalogDatabase) async throws -> String {
        let snapshot = try await catalog.workflowInputSnapshot(assetIDs: Set(assetIDs))
        let definition = try WorkflowDefinition(name: "CLI apply \(tagName.rawValue)", trigger: .manualSelection, actions: [.proposeTag(tagName.rawValue)])
        let plan = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)
        try await catalog.workflows.store(definition, at: .now)
        let run = try await catalog.workflows.enqueue(plan: plan, actor: .agent, at: .now)
        let expiry = Date().addingTimeInterval(15 * 60)
        let token = try await catalog.workflows.issueLocalCLIApprovalToken(workflowRunID: run.id, expiresAt: expiry, at: .now)
        return try encode(ProposalResponse(operationID: run.id.uuidString.lowercased(), state: run.state.rawValue, targetAssetIDs: plan.snapshot.assetIDs.map(\.description), action: "addTags", tagName: tagName.rawValue, catalogRevision: plan.snapshot.catalogRevision, sourceFingerprint: plan.snapshot.sourceFingerprint, approvalToken: token, approvalExpiresAt: expiry, dryRun: true))
    }

    private static func operationResponse(workflowRunID: UUID, catalog: CatalogDatabase) async throws -> String {
        guard let run = try await catalog.workflows.workflowRun(id: workflowRunID), let proposal = try await catalog.workflows.proposal(for: workflowRunID) else {
            throw FramebaseCLIError.invalidIdentifier(workflowRunID.uuidString)
        }
        let audit = try await catalog.workflows.auditEvents(for: workflowRunID)
        return try encode(OperationResponse(operationID: run.id.uuidString.lowercased(), state: run.state.rawValue, proposalState: proposal.state.rawValue, targetAssetIDs: proposal.plan.snapshot.assetIDs.map(\.description), catalogRevision: proposal.plan.snapshot.catalogRevision, sourceFingerprint: proposal.plan.snapshot.sourceFingerprint, auditKinds: audit.map { $0.kind.rawValue }))
    }

    private static func encode<Value: Encodable>(_ response: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(response), as: UTF8.self)
    }

    private enum CommandKind {
        case diagnostics, listFolders, search(String), inspect(AssetID)
        case proposeTag([AssetID], TagName)
        case getOperation(UUID), apply(UUID, String)
    }

    private struct Command {
        let kind: CommandKind
        let catalogURL: URL

        init(arguments: [String]) throws {
            guard let name = arguments.first else { throw FramebaseCLIError.missingCommand }
            var values = Array(arguments.dropFirst())
            let catalogURL = try Self.value(for: "--catalog", in: &values).map(URL.init(fileURLWithPath:))
            guard let catalogURL else { throw FramebaseCLIError.missingCatalogPath }
            switch name {
            case "diagnostics": kind = .diagnostics
            case "list-folders": kind = .listFolders
            case "search":
                guard let text = try Self.value(for: "--text", in: &values), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FramebaseCLIError.missingSearchText }
                kind = .search(text)
            case "inspect": kind = .inspect(try Self.assetID(from: try Self.requiredValue(for: "--asset", in: &values)))
            case "proposal":
                guard values.first == "tag" else { throw FramebaseCLIError.unsupportedCommand(values.first ?? "proposal") }
                values.removeFirst()
                let assetIDs = try Self.assetIDs(from: Self.values(for: "--asset", in: &values))
                guard let rawTag = try Self.value(for: "--tag", in: &values) else { throw FramebaseCLIError.missingTagName }
                kind = .proposeTag(assetIDs, try TagName(rawTag))
            case "get-operation": kind = .getOperation(try Self.uuid(from: try Self.requiredValue(for: "--operation", in: &values)))
            case "apply":
                let operationID = try Self.uuid(from: try Self.requiredValue(for: "--operation", in: &values))
                let token = try Self.requiredValue(for: "--approval", in: &values)
                kind = .apply(operationID, token)
            default: throw FramebaseCLIError.unsupportedCommand(name)
            }
            if let unexpected = values.first { throw FramebaseCLIError.unexpectedArgument(unexpected) }
            self.catalogURL = catalogURL
        }

        private static func requiredValue(for flag: String, in values: inout [String]) throws -> String {
            guard let value = try value(for: flag, in: &values) else {
                switch flag {
                case "--asset": throw FramebaseCLIError.missingAssetID
                case "--operation": throw FramebaseCLIError.missingOperationID
                case "--approval": throw FramebaseCLIError.missingApprovalToken
                default: throw FramebaseCLIError.unexpectedArgument(flag)
                }
            }
            return value
        }

        private static func value(for flag: String, in values: inout [String]) throws -> String? {
            guard let index = values.firstIndex(of: flag) else { return nil }
            let valueIndex = values.index(after: index)
            guard valueIndex < values.endIndex else { throw FramebaseCLIError.unexpectedArgument(flag) }
            let value = values[valueIndex]
            values.removeSubrange(index...valueIndex)
            return value
        }

        private static func values(for flag: String, in values: inout [String]) -> [String] {
            var matches: [String] = []
            while let index = values.firstIndex(of: flag), values.index(after: index) < values.endIndex {
                let valueIndex = values.index(after: index)
                matches.append(values[valueIndex])
                values.removeSubrange(index...valueIndex)
            }
            return matches
        }

        private static func assetIDs(from values: [String]) throws -> [AssetID] {
            guard !values.isEmpty else { throw FramebaseCLIError.missingAssetID }
            return try values.map(assetID(from:))
        }

        private static func assetID(from value: String) throws -> AssetID { AssetID(rawValue: try uuid(from: value)) }
        private static func uuid(from value: String) throws -> UUID {
            guard let identifier = UUID(uuidString: value) else { throw FramebaseCLIError.invalidIdentifier(value) }
            return identifier
        }
    }

    private struct DiagnosticsResponse: Encodable { let catalogID: String; let schemaVersion: Int; let folderCount: Int; let assetCount: Int }
    private struct FolderResponse: Encodable {
        let id: String; let name: String; let parentFolderID: String?; let systemKind: String?
        init(_ folder: Folder) { id = folder.id.description; name = folder.name.rawValue; parentFolderID = folder.parentFolderID?.description; systemKind = folder.systemKind?.rawValue }
    }
    private struct AssetResponse: Encodable {
        let id: String; let displayName: String; let fileSize: Int64; let width: Int?; let height: Int?; let favorite: Bool; let rating: Int; let originalAvailable: Bool
        init(_ asset: AssetGridRecord) { id = asset.id.description; displayName = asset.displayName; fileSize = asset.fileSize; width = asset.width; height = asset.height; favorite = asset.favorite; rating = asset.rating.rawValue; originalAvailable = asset.originalAvailable }
        init(_ asset: Asset) { id = asset.id.description; displayName = asset.displayName; fileSize = asset.fileSize; width = asset.width; height = asset.height; favorite = asset.favorite; rating = asset.rating.rawValue; originalAvailable = asset.localURL != nil }
    }
    private struct SearchResponse: Encodable { let totalCount: Int; let assets: [AssetResponse] }
    private struct InspectionResponse: Encodable { let asset: AssetResponse; let tagNames: [String] }
    private struct ProposalResponse: Encodable { let operationID: String; let state: String; let targetAssetIDs: [String]; let action: String; let tagName: String; let catalogRevision: Int64; let sourceFingerprint: String; let approvalToken: String; let approvalExpiresAt: Date; let dryRun: Bool }
    private struct OperationResponse: Encodable { let operationID: String; let state: String; let proposalState: String; let targetAssetIDs: [String]; let catalogRevision: Int64; let sourceFingerprint: String; let auditKinds: [String] }
}
