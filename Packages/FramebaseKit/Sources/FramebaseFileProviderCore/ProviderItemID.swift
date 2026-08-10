import Foundation
import FramebaseDomain

public enum ProviderItemID: Hashable, Sendable, Codable {
    case root(CatalogID)
    case folder(FolderID)
    case asset(AssetID)
    case trash(CatalogID)

    public var rawValue: String {
        switch self {
        case let .root(catalogID):
            Self.makeRawValue(kind: "root", identifier: catalogID.rawValue)
        case let .folder(folderID):
            Self.makeRawValue(kind: "folder", identifier: folderID.rawValue)
        case let .asset(assetID):
            Self.makeRawValue(kind: "asset", identifier: assetID.rawValue)
        case let .trash(catalogID):
            Self.makeRawValue(kind: "trash", identifier: catalogID.rawValue)
        }
    }

    public static func parse(_ rawValue: String) throws -> ProviderItemID {
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 5,
              components[0] == "fb:",
              components[1].isEmpty,
              components[2] == "v1",
              !components[3].isEmpty,
              let rawIdentifier = UUID(uuidString: String(components[4])) else {
            throw ProviderItemIDError.malformed(rawValue)
        }

        switch components[3] {
        case "root":
            return .root(CatalogID(rawValue: rawIdentifier))
        case "folder":
            return .folder(FolderID(rawValue: rawIdentifier))
        case "asset":
            return .asset(AssetID(rawValue: rawIdentifier))
        case "trash":
            return .trash(CatalogID(rawValue: rawIdentifier))
        default:
            throw ProviderItemIDError.unsupportedKind(String(components[3]))
        }
    }

    private static func makeRawValue(kind: String, identifier: UUID) -> String {
        "fb://v1/\(kind)/\(identifier.uuidString.lowercased())"
    }
}

public enum ProviderItemIDError: Error, Equatable, Sendable {
    case malformed(String)
    case unsupportedKind(String)
}
