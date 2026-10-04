import Foundation

public enum OriginalReceiveDisposition: String, Codable, Equatable, Sendable {
    case imported
    case alreadyPresent
}

/// Where the original bytes stand relative to the development R2 bucket.
public enum OriginalBlobDisposition: String, Codable, Equatable, Sendable {
    case localOnly
    case uploaded
    case alreadyInR2
}

public struct OriginalReceiveItem: Codable, Equatable, Sendable {
    public let filename: String
    public let assetID: String
    public let disposition: OriginalReceiveDisposition
    public let blob: OriginalBlobDisposition

    public init(filename: String, assetID: String, disposition: OriginalReceiveDisposition, blob: OriginalBlobDisposition) {
        self.filename = filename
        self.assetID = assetID
        self.disposition = disposition
        self.blob = blob
    }
}

public struct OriginalReceiveReport: Codable, Equatable, Sendable {
    public let librarySpace: String
    public let bucket: String
    public let items: [OriginalReceiveItem]
    public let failureFilenames: [String]

    public init(librarySpace: String, bucket: String, items: [OriginalReceiveItem], failureFilenames: [String]) {
        self.librarySpace = librarySpace
        self.bucket = bucket
        self.items = items
        self.failureFilenames = failureFilenames
    }
}

/// Where a received original is filed inside its library.
///
/// Personal uses the year directory already present in the source path.
/// Hair Solutions uses `00_inbox`. Neither path reads EXIF to choose a folder.
public enum OriginalReceivePlacement {
    public static let firstPersonalYear = 2010
    public static let lastPersonalYear = 2026
    public static let hairSolutionsInboxName = "00_inbox"
    public static let developmentAPIHost = "framebase-api-dev.notionsync.workers.dev"
    public static let approvedProductionAPIHost = "framebase-api-prod.notionsync.workers.dev"

    /// The nearest parent directory whose name is a year from 2010 through 2026.
    public static func personalYearName(in fileURL: URL) -> String? {
        let years = Set((firstPersonalYear...lastPersonalYear).map(String.init))
        var current = fileURL.standardizedFileURL.deletingLastPathComponent()
        var previous = ""
        while current.path != previous {
            let name = current.lastPathComponent
            if years.contains(name) { return name }
            previous = current.path
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }
}

public enum OriginalReceiveAPIPolicy {
    /// Accepts the development Worker and the one approved production Worker URL.
    /// `hsc-media-origin` and every other production host are refused.
    public static func validate(_ url: URL) throws {
        let host = url.host?.lowercased() ?? ""
        let absolute = url.absoluteString.lowercased()
        if absolute.contains("hsc-media-origin")
            || absolute.contains("framebase-blobs-prod")
            || absolute.contains("framebase-catalog-prod") {
            throw OriginalReceiveError.productionTargetRefused
        }
        if host == OriginalReceivePlacement.approvedProductionAPIHost {
            guard url.scheme?.lowercased() == "https",
                  url.user == nil,
                  url.password == nil,
                  url.port == nil,
                  url.path.isEmpty || url.path == "/",
                  url.query == nil,
                  url.fragment == nil else {
                throw OriginalReceiveError.productionTargetRefused
            }
            return
        }
        if host.contains("framebase-api-prod") || absolute.contains("framebase-api-prod") {
            throw OriginalReceiveError.productionTargetRefused
        }
    }
}

public enum OriginalReceiveError: Error, Equatable, LocalizedError, Sendable {
    case notALibraryPackage
    case librarySpaceMismatch(existing: LibrarySpace?, requested: LibrarySpace)
    case sourceInsideLibrary
    case unreadableImage(String)
    case missingSourceYear(String)
    case stagingRecoveryFailed
    case cloudCredentialsIncomplete
    case productionTargetRefused
    case directUploadRequired

    public var errorDescription: String? {
        switch self {
        case .notALibraryPackage:
            "Pass a .framebase library package."
        case let .librarySpaceMismatch(existing, requested):
            if let existing {
                "This library is \(existing.displayName) and cannot receive \(requested.displayName) originals."
            } else {
                "This package is not the \(requested.displayName)."
            }
        case .sourceInsideLibrary:
            "Originals must be copied from outside the library package."
        case let .unreadableImage(name):
            "Framebase could not read \(name) as an image."
        case let .missingSourceYear(name):
            "Personal originals need a parent folder named with a year from 2010 through 2026. \(name) has none."
        case .stagingRecoveryFailed:
            "Staging recovery failed. No originals were imported."
        case .cloudCredentialsIncomplete:
            "Pass both --api and --token to store originals in framebase-blobs-dev, or neither to stay local."
        case .productionTargetRefused:
            "Pass the development API, or pass https://framebase-api-prod.notionsync.workers.dev explicitly. hsc-media-origin is not a receive target."
        case .directUploadRequired:
            "Original bytes must upload directly to framebase-blobs-dev, not through the Worker."
        }
    }
}

public protocol OriginalReceiveCatalog: Sendable {
    var inboxFolderID: FolderID { get }
    func librarySpace() async throws -> LibrarySpace?
    func assignLibrarySpace(_ space: LibrarySpace) async throws
    func assetID(forContentSHA256 sha256: String) async throws -> AssetID?
    func asset(id: AssetID) async throws -> Asset?
    func insertOriginal(_ asset: Asset, contentSHA256: String) async throws
    func ensureRootFolder(named name: String) async throws -> FolderID
}
