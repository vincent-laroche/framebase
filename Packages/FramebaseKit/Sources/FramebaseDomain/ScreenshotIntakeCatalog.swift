import Foundation

/// Errors for the local screenshot content-hash identity.
public enum ScreenshotContentIdentityError: Error, Equatable, LocalizedError, Sendable {
    case duplicateContent
    case invalidContentSHA256

    public var errorDescription: String? {
        switch self {
        case .duplicateContent:
            "These original bytes are already in this library."
        case .invalidContentSHA256:
            "The screenshot content hash is not a SHA-256 digest."
        }
    }
}

public enum ScreenshotIntakeDisposition: String, Codable, Equatable, Sendable {
    case imported
    case alreadyPresent
}

public struct ScreenshotIntakeItem: Codable, Equatable, Sendable {
    public let filename: String
    public let assetID: String
    public let disposition: ScreenshotIntakeDisposition
    public let recognizedText: String

    public init(filename: String, assetID: String, disposition: ScreenshotIntakeDisposition, recognizedText: String) {
        self.filename = filename
        self.assetID = assetID
        self.disposition = disposition
        self.recognizedText = recognizedText
    }
}

public struct ScreenshotIntakeReport: Codable, Equatable, Sendable {
    public let librarySpace: String
    public let items: [ScreenshotIntakeItem]
    public let failureFilenames: [String]

    public init(librarySpace: String, items: [ScreenshotIntakeItem], failureFilenames: [String]) {
        self.librarySpace = librarySpace
        self.items = items
        self.failureFilenames = failureFilenames
    }
}

public enum ScreenshotIntakeError: Error, Equatable, LocalizedError, Sendable {
    case notALibraryPackage
    case notScreenshotsLibrary
    case inboxOverlapsLibrary
    case inboxUnavailable
    case stagingRecoveryFailed
    case unreadableImage(String)

    public var errorDescription: String? {
        switch self {
        case .notALibraryPackage:
            "Screenshot intake needs a .framebase library package."
        case .notScreenshotsLibrary:
            "Screenshot intake only writes the Screenshots library. Personal and Hair Solutions stay unchanged."
        case .inboxOverlapsLibrary:
            "The screenshot inbox must be a folder outside the library package."
        case .inboxUnavailable:
            "The screenshot inbox is not a folder that can be read."
        case .stagingRecoveryFailed:
            "Framebase could not recover leftover staging files, so screenshot intake did not copy anything."
        case let .unreadableImage(filename):
            "Framebase could not read the screenshot \(filename)."
        }
    }
}

/// Catalog operations the screenshot intake needs.
///
/// Media depends on this protocol instead of the catalog module. OCR storage
/// is explicit and does not move, tag, or album the asset.
public protocol ScreenshotIntakeCatalog: Sendable {
    var inboxFolderID: FolderID { get }

    func librarySpace() async throws -> LibrarySpace?
    func assignLibrarySpace(_ space: LibrarySpace) async throws
    func assetID(forContentSHA256 sha256: String) async throws -> AssetID?
    func asset(id: AssetID) async throws -> Asset?
    func insertScreenshot(_ asset: Asset, contentSHA256: String) async throws
    func storeAnalysis(_ result: AssetAnalysisResult) async throws
    func succeededOCRText(for assetID: AssetID) async throws -> String?
}
