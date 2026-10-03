import Foundation
import FramebaseCatalog
import FramebaseDomain
import FramebaseMedia

extension FramebaseCLI {
    static func ingestScreenshots(arguments: [String]) async throws -> String {
        var values = arguments
        let libraryPath = try flagValue("--library", in: &values)
        let inboxPath = try flagValue("--inbox", in: &values)
        if let unexpected = values.first {
            throw FramebaseCLIError.unexpectedArgument(unexpected)
        }

        let libraryURL = libraryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ScreenshotLibraryPackage.defaultLibraryRootURL()
        let inboxURL = inboxPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ScreenshotLibraryPackage.defaultInboxURL()
        let package = try ScreenshotLibraryPackage(rootURL: libraryURL)
        try ScreenshotLibraryPackage.validateSeparated(inbox: inboxURL, libraryRoot: package.rootURL)

        let catalogExists = FileManager.default.fileExists(atPath: package.catalogDatabaseURL.path)
        if !catalogExists, package.rootURL.lastPathComponent != LibrarySpace.screenshots.packageName {
            throw ScreenshotIntakeError.notScreenshotsLibrary
        }

        try package.prepare()
        try ScreenshotLibraryPackage.prepareInbox(at: inboxURL)

        let catalog = try CatalogDatabase(catalogURL: package.catalogDatabaseURL)
        let blobStore = try ManagedAssetBlobStore(
            originalsDirectoryURL: package.originalsDirectoryURL,
            stagingDirectoryURL: package.stagingDirectoryURL
        )
        let recovery = try await blobStore.recoverStaging()
        if !recovery.failedURLs.isEmpty {
            throw ScreenshotIntakeError.stagingRecoveryFailed
        }

        let intake = ScreenshotIntake(
            catalog: catalog,
            blobStore: blobStore,
            intelligence: VisionIntelligenceService(),
            libraryRootURL: package.rootURL
        )
        let report = try await intake.ingest(inboxURL: inboxURL)
        return try encode(report)
    }

    static func flagValue(_ flag: String, in values: inout [String]) throws -> String? {
        guard let index = values.firstIndex(of: flag) else { return nil }
        let valueIndex = values.index(after: index)
        guard valueIndex < values.endIndex else { throw FramebaseCLIError.unexpectedArgument(flag) }
        let value = values[valueIndex]
        values.removeSubrange(index...valueIndex)
        return value
    }
}
