import CryptoKit
import Foundation
import FramebaseDomain

/// Layout for the Screenshots library package and the folder a Shortcut drops into.
///
/// The package matches the app's `Catalog/`, `Originals/`, and `Staging/` directories.
/// The inbox stays outside that package. Dropped files are never deleted.
public struct ScreenshotLibraryPackage: Sendable {
    public static let inboxDirectoryName = "Framebase Screenshot Inbox"

    public let rootURL: URL

    public init(rootURL: URL) throws {
        let standardized = rootURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "framebase" else {
            throw ScreenshotIntakeError.notALibraryPackage
        }
        self.rootURL = standardized
    }

    public var catalogDirectoryURL: URL { rootURL.appendingPathComponent("Catalog", isDirectory: true) }
    public var catalogDatabaseURL: URL { catalogDirectoryURL.appendingPathComponent("catalog.sqlite", isDirectory: false) }
    public var originalsDirectoryURL: URL { rootURL.appendingPathComponent("Originals", isDirectory: true) }
    public var stagingDirectoryURL: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }

    public static func defaultLibraryRootURL(fileManager: FileManager = .default) -> URL {
        let pictures = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent(LibrarySpace.screenshots.packageName, isDirectory: true)
    }

    /// iCloud Drive when that container exists, so an iPhone Shortcut and the Mac
    /// daily job share one folder. Otherwise `~/Pictures/Framebase Screenshot Inbox`.
    public static func defaultInboxURL(fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: iCloud.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return iCloud.appendingPathComponent(inboxDirectoryName, isDirectory: true)
        }
        let pictures = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for url in [rootURL, catalogDirectoryURL, originalsDirectoryURL, stagingDirectoryURL] {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let fileType = attributes[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink {
                throw ScreenshotIntakeError.notALibraryPackage
            }
            guard fileType == .typeDirectory else {
                throw ScreenshotIntakeError.notALibraryPackage
            }
        }
    }

    public static func prepareInbox(at url: URL, fileManager: FileManager = .default) throws {
        let inbox = url.standardizedFileURL
        if !fileManager.fileExists(atPath: inbox.path) {
            try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        let attributes = try fileManager.attributesOfItem(atPath: inbox.path)
        let fileType = attributes[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink || fileType != .typeDirectory {
            throw ScreenshotIntakeError.inboxUnavailable
        }
    }

    public static func validateSeparated(inbox inboxURL: URL, libraryRoot: URL) throws {
        if path(inboxURL, isInside: libraryRoot) || path(libraryRoot, isInside: inboxURL) {
            throw ScreenshotIntakeError.inboxOverlapsLibrary
        }
    }

    static func path(_ url: URL, isInside parent: URL) -> Bool {
        let child = url.resolvingSymlinksInPath().standardizedFileURL.path
        var parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        if child == parentPath { return true }
        if !parentPath.hasSuffix("/") { parentPath += "/" }
        return child.hasPrefix(parentPath)
    }
}

/// Copies new screenshots into one Screenshots library and stores local OCR text.
///
/// Identity is the SHA-256 of the original file bytes. The same screenshot seen
/// under another filename, or again on a later pass, stays one asset. Analysis
/// requests OCR only and does not tag, move, or album the asset. Source files
/// stay in the inbox.
public actor ScreenshotIntake {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "webp"]

    private let catalog: any ScreenshotIntakeCatalog
    private let blobStore: any AssetBlobStore
    private let metadataExtractor: any MetadataExtractor
    private let intelligence: any IntelligenceService
    private let libraryRootURL: URL
    private var seenHashes: [String: AssetID] = [:]

    public init(
        catalog: any ScreenshotIntakeCatalog,
        blobStore: any AssetBlobStore,
        metadataExtractor: any MetadataExtractor = ImageIOMetadataExtractor(),
        intelligence: any IntelligenceService,
        libraryRootURL: URL
    ) {
        self.catalog = catalog
        self.blobStore = blobStore
        self.metadataExtractor = metadataExtractor
        self.intelligence = intelligence
        self.libraryRootURL = libraryRootURL.standardizedFileURL
    }

    public func ingest(inboxURL: URL) async throws -> ScreenshotIntakeReport {
        try ScreenshotLibraryPackage.validateSeparated(inbox: inboxURL, libraryRoot: libraryRootURL)
        try await requireScreenshotsLibrary()
        let inbox = try Self.readableInbox(inboxURL)
        let sources = try Self.imageFiles(in: inbox)
        var items: [ScreenshotIntakeItem] = []
        var failures: [String] = []
        seenHashes = [:]

        for source in sources {
            do {
                items.append(try await ingestOne(sourceURL: source))
            } catch {
                failures.append(source.lastPathComponent)
                _ = try? await blobStore.recoverStaging()
            }
        }

        return ScreenshotIntakeReport(
            librarySpace: LibrarySpace.screenshots.rawValue,
            items: items,
            failureFilenames: failures
        )
    }

    private func requireScreenshotsLibrary() async throws {
        if let space = try await catalog.librarySpace() {
            guard space == .screenshots else { throw ScreenshotIntakeError.notScreenshotsLibrary }
            return
        }
        guard libraryRootURL.lastPathComponent == LibrarySpace.screenshots.packageName else {
            throw ScreenshotIntakeError.notScreenshotsLibrary
        }
        try await catalog.assignLibrarySpace(.screenshots)
    }

    private func ingestOne(sourceURL: URL) async throws -> ScreenshotIntakeItem {
        let filename = sourceURL.lastPathComponent
        let hash = try Self.contentHash(of: sourceURL)
        guard hash.byteCount > 0 else { throw ScreenshotIntakeError.unreadableImage(filename) }

        let existingID: AssetID?
        if let cached = seenHashes[hash.digest] {
            existingID = cached
        } else {
            existingID = try await catalog.assetID(forContentSHA256: hash.digest)
        }
        if let assetID = existingID {
            seenHashes[hash.digest] = assetID
            guard let asset = try await catalog.asset(id: assetID) else {
                throw ScreenshotIntakeError.unreadableImage(filename)
            }
            let text = try await recognize(asset)
            return ScreenshotIntakeItem(
                filename: filename,
                assetID: assetID.description,
                disposition: .alreadyPresent,
                recognizedText: text
            )
        }

        let imported = try await importNew(sourceURL: sourceURL, hash: hash)
        seenHashes[hash.digest] = imported.asset.id
        let text = try await recognize(imported.asset)
        return ScreenshotIntakeItem(
            filename: filename,
            assetID: imported.asset.id.description,
            disposition: imported.disposition,
            recognizedText: text
        )
    }

    private func importNew(sourceURL: URL, hash: ContentHash) async throws -> (asset: Asset, disposition: ScreenshotIntakeDisposition) {
        let filename = sourceURL.lastPathComponent
        let assetID = AssetID()
        let staged: StagedBlob
        do {
            staged = try await blobStore.stage(sourceURL: sourceURL, for: assetID)
        } catch {
            throw error
        }

        guard await metadataExtractor.supportsImage(at: staged.stagingURL) else {
            _ = try? await blobStore.recoverStaging()
            throw ScreenshotIntakeError.unreadableImage(filename)
        }

        let extracted: ExtractedAssetMetadata
        do {
            extracted = try await metadataExtractor.extract(from: staged.stagingURL)
        } catch {
            _ = try? await blobStore.recoverStaging()
            throw error
        }

        var metadata = extracted.metadata
        metadata.file.filenameExtension = sourceURL.pathExtension.isEmpty ? nil : sourceURL.pathExtension.lowercased()

        let committed: CommittedBlob
        do {
            committed = try await blobStore.commit(staged)
        } catch {
            _ = try? await blobStore.recoverStaging()
            throw error
        }

        guard committed.fileSize == hash.byteCount, committed.fileSize > 0 else {
            try? await blobStore.removeNewlyCommitted(committed)
            throw ScreenshotIntakeError.unreadableImage(filename)
        }

        let now = Date()
        let sourceCreatedAt = try? sourceURL.resourceValues(forKeys: [.creationDateKey]).creationDate
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let displayName = baseName.isEmpty ? filename : baseName
        let asset = Asset(
            id: assetID,
            filename: filename,
            displayName: displayName,
            parentFolderID: catalog.inboxFolderID,
            storageKey: committed.storageKey,
            localURL: committed.localURL,
            width: extracted.width,
            height: extracted.height,
            fileSize: committed.fileSize,
            createdAt: extracted.createdAt ?? sourceCreatedAt ?? committed.modifiedAt,
            modifiedAt: committed.modifiedAt,
            importedAt: now,
            updatedAt: now,
            metadata: metadata
        )

        do {
            try await catalog.insertScreenshot(asset, contentSHA256: hash.digest)
            return (asset, .imported)
        } catch ScreenshotContentIdentityError.duplicateContent {
            try? await blobStore.removeNewlyCommitted(committed)
            guard let existingID = try await catalog.assetID(forContentSHA256: hash.digest),
                  let existing = try await catalog.asset(id: existingID) else {
                throw ScreenshotIntakeError.unreadableImage(filename)
            }
            return (existing, .alreadyPresent)
        } catch {
            try? await blobStore.removeNewlyCommitted(committed)
            throw error
        }
    }

    private func recognize(_ asset: Asset) async throws -> String {
        if let existing = try await catalog.succeededOCRText(for: asset.id) {
            return existing
        }
        let sourceURL = try await sourceURL(for: asset)
        let request = try AssetAnalysisRequest(assetID: asset.id, kinds: [.ocr])
        let results = try await intelligence.analyze(request, sourceURL: sourceURL)
        for result in results where result.kind == .ocr {
            try await catalog.storeAnalysis(result)
        }
        return try await catalog.succeededOCRText(for: asset.id) ?? ""
    }

    private func sourceURL(for asset: Asset) async throws -> URL {
        if let localURL = asset.localURL {
            return localURL
        }
        return try await blobStore.resolve(asset.storageKey)
    }

    private struct ContentHash: Equatable {
        let digest: String
        let byteCount: Int64
    }

    private static func contentHash(of url: URL) throws -> ContentHash {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while true {
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            count += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ContentHash(digest: digest, byteCount: count)
    }

    private static func readableInbox(_ url: URL) throws -> URL {
        let inbox = url.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inbox.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScreenshotIntakeError.inboxUnavailable
        }
        let attributes = try fileManager.attributesOfItem(atPath: inbox.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ScreenshotIntakeError.inboxUnavailable
        }
        return inbox
    }

    private static func imageFiles(in inbox: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            return values?.isSymbolicLink != true && values?.isDirectory != true && values?.isRegularFile == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
