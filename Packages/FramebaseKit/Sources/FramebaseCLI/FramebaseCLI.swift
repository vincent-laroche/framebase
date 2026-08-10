import Foundation
import FramebaseCatalog
import FramebaseDomain

public enum FramebaseCLIError: LocalizedError, Equatable, Sendable {
    case missingCommand
    case unsupportedCommand(String)
    case missingCatalogPath
    case missingSearchText
    case unexpectedArgument(String)

    public var errorDescription: String? {
        switch self {
        case .missingCommand:
            "Choose diagnostics, list-folders, or search."
        case let .unsupportedCommand(command):
            "Unsupported command: \(command)."
        case .missingCatalogPath:
            "Pass --catalog followed by a catalog.sqlite path."
        case .missingSearchText:
            "Pass --text followed by a search value."
        case let .unexpectedArgument(argument):
            "Unexpected argument: \(argument)."
        }
    }
}

/// Local, read-only foundation for the `framebase` command. It deliberately
/// exposes catalog metadata only: no managed-original paths, bytes, cloud
/// credentials, or mutation command exists here.
public enum FramebaseCLI {
    public static let usage = """
    Usage:
      framebase diagnostics --catalog /path/to/catalog.sqlite
      framebase list-folders --catalog /path/to/catalog.sqlite
      framebase search --catalog /path/to/catalog.sqlite --text "query"

    The current local CLI is read-only. It never exposes managed-original paths,
    storage keys, cloud credentials, or a permanent-purge command.
    """

    public static func execute(arguments: [String]) async throws -> String {
        if arguments == ["--help"] || arguments == ["help"] { return usage }
        let command = try Command(arguments: arguments)
        let catalog = try CatalogDatabase(catalogURL: command.catalogURL)

        switch command.kind {
        case .diagnostics:
            let folders = try await catalog.folders.treeSnapshot()
            let assets = try await catalog.assets.count(matching: AssetQuery(scope: .allAssets))
            return try Self.encode(DiagnosticsResponse(
                catalogID: catalog.catalogID.description,
                schemaVersion: FramebaseCatalogFoundation.currentSchemaVersion,
                folderCount: folders.folders.count,
                assetCount: assets
            ))
        case .listFolders:
            let snapshot = try await catalog.folders.treeSnapshot()
            return try Self.encode(snapshot.folders.map(FolderResponse.init))
        case let .search(text):
            let page = try await catalog.assets.page(
                matching: AssetQuery(scope: .allAssets, filter: AssetFilter(text: text)),
                sortedBy: .defaultSort,
                offset: 0,
                limit: 200
            )
            return try Self.encode(SearchResponse(totalCount: page.totalCount, assets: page.records.map(AssetResponse.init)))
        }
    }

    private static func encode<Value: Encodable>(_ response: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(response), as: UTF8.self)
    }

    private enum CommandKind {
        case diagnostics
        case listFolders
        case search(text: String)
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
            case "diagnostics":
                kind = .diagnostics
            case "list-folders":
                kind = .listFolders
            case "search":
                guard let text = try Self.value(for: "--text", in: &values), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FramebaseCLIError.missingSearchText
                }
                kind = .search(text: text)
            default:
                throw FramebaseCLIError.unsupportedCommand(name)
            }
            if let unexpected = values.first { throw FramebaseCLIError.unexpectedArgument(unexpected) }
            self.catalogURL = catalogURL
        }

        private static func value(for flag: String, in values: inout [String]) throws -> String? {
            guard let index = values.firstIndex(of: flag) else { return nil }
            let valueIndex = values.index(after: index)
            guard valueIndex < values.endIndex else { throw FramebaseCLIError.unexpectedArgument(flag) }
            let value = values[valueIndex]
            values.removeSubrange(index...valueIndex)
            return value
        }
    }

    private struct DiagnosticsResponse: Encodable {
        let catalogID: String
        let schemaVersion: Int
        let folderCount: Int
        let assetCount: Int
    }

    private struct FolderResponse: Encodable {
        let id: String
        let name: String
        let parentFolderID: String?
        let systemKind: String?

        init(_ folder: Folder) {
            id = folder.id.description
            name = folder.name.rawValue
            parentFolderID = folder.parentFolderID?.description
            systemKind = folder.systemKind?.rawValue
        }
    }

    private struct AssetResponse: Encodable {
        let id: String
        let displayName: String
        let fileSize: Int64
        let width: Int?
        let height: Int?
        let favorite: Bool
        let rating: Int
        let originalAvailable: Bool

        init(_ asset: AssetGridRecord) {
            id = asset.id.description
            displayName = asset.displayName
            fileSize = asset.fileSize
            width = asset.width
            height = asset.height
            favorite = asset.favorite
            rating = asset.rating.rawValue
            originalAvailable = asset.originalAvailable
        }
    }

    private struct SearchResponse: Encodable {
        let totalCount: Int
        let assets: [AssetResponse]
    }
}
