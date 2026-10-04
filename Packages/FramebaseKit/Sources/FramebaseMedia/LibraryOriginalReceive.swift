import CryptoKit
import Foundation
import FramebaseDomain

/// Layout shared by Personal, Hair Solutions, and Screenshots packages.
public struct FramebaseLibraryPackage: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) throws {
        let standardized = rootURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "framebase" else {
            throw OriginalReceiveError.notALibraryPackage
        }
        self.rootURL = standardized
    }

    public var catalogDirectoryURL: URL { rootURL.appendingPathComponent("Catalog", isDirectory: true) }
    public var catalogDatabaseURL: URL { catalogDirectoryURL.appendingPathComponent("catalog.sqlite", isDirectory: false) }
    public var originalsDirectoryURL: URL { rootURL.appendingPathComponent("Originals", isDirectory: true) }
    public var stagingDirectoryURL: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }

    public static let legacyPersonalPackageName = "Framebase Library.framebase"

    public func matches(_ space: LibrarySpace) -> Bool {
        let name = rootURL.lastPathComponent
        if name == space.packageName { return true }
        return space == .personal && name == Self.legacyPersonalPackageName
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for url in [rootURL, catalogDirectoryURL, originalsDirectoryURL, stagingDirectoryURL] {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let fileType = attributes[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink || fileType != .typeDirectory {
                throw OriginalReceiveError.notALibraryPackage
            }
        }
    }
}

/// Copies original image bytes into one library space.
///
/// Identity is the SHA-256 of the source file. The same bytes are one asset.
/// Source files stay where they are. This path does not run OCR or any model.
public actor LibraryOriginalReceive {
    private let space: LibrarySpace
    private let catalog: any OriginalReceiveCatalog
    private let blobStore: ManagedAssetBlobStore
    private let metadataExtractor: any MetadataExtractor
    private let libraryRootURL: URL
    private var seenHashes: [String: AssetID] = [:]

    public init(
        space: LibrarySpace,
        catalog: any OriginalReceiveCatalog,
        blobStore: ManagedAssetBlobStore,
        metadataExtractor: any MetadataExtractor = ImageIOMetadataExtractor(),
        libraryRootURL: URL
    ) {
        self.space = space
        self.catalog = catalog
        self.blobStore = blobStore
        self.metadataExtractor = metadataExtractor
        self.libraryRootURL = libraryRootURL.standardizedFileURL
    }

    public func receive(sources: [URL]) async throws -> [LocalOriginalReceipt] {
        try await requireSpace()
        for source in sources where Self.path(source, isInside: libraryRootURL) {
            throw OriginalReceiveError.sourceInsideLibrary
        }
        var receipts: [LocalOriginalReceipt] = []
        for source in sources {
            for file in try Self.imageFiles(at: source) {
                receipts.append(try await receiveOne(sourceURL: file))
            }
        }
        return receipts
    }

    private func requireSpace() async throws {
        if let existing = try await catalog.librarySpace() {
            guard existing == space else {
                throw OriginalReceiveError.librarySpaceMismatch(existing: existing, requested: space)
            }
            return
        }
        guard try FramebaseLibraryPackage(rootURL: libraryRootURL).matches(space) else {
            throw OriginalReceiveError.librarySpaceMismatch(existing: nil, requested: space)
        }
        try await catalog.assignLibrarySpace(space)
    }

    private func receiveOne(sourceURL: URL) async throws -> LocalOriginalReceipt {
        let filename = sourceURL.lastPathComponent
        let hash = try Self.contentHash(of: sourceURL)
        guard hash.byteCount > 0, let mediaType = Self.mediaType(for: sourceURL.pathExtension) else {
            throw OriginalReceiveError.unreadableImage(filename)
        }
        let existingID: AssetID?
        if let cached = seenHashes[hash.digest] {
            existingID = cached
        } else {
            existingID = try await catalog.assetID(forContentSHA256: hash.digest)
        }
        if let assetID = existingID {
            seenHashes[hash.digest] = assetID
            guard let asset = try await catalog.asset(id: assetID) else {
                throw OriginalReceiveError.unreadableImage(filename)
            }
            return LocalOriginalReceipt(
                filename: filename,
                asset: asset,
                disposition: .alreadyPresent,
                sha256: hash.digest,
                mediaType: mediaType,
                originalExtension: Self.normalizedExtension(sourceURL.pathExtension),
                fileURL: try await blobStore.resolve(asset.storageKey)
            )
        }
        let imported = try await importNew(sourceURL: sourceURL, hash: hash, mediaType: mediaType)
        seenHashes[hash.digest] = imported.asset.id
        return imported
    }

    private func importNew(sourceURL: URL, hash: ContentHash, mediaType: String) async throws -> LocalOriginalReceipt {
        let filename = sourceURL.lastPathComponent
        let parentFolderID = try await destinationFolderID(for: sourceURL)
        let assetID = AssetID()
        let staged: StagedBlob
        do {
            staged = try await blobStore.stage(sourceURL: sourceURL, for: assetID)
        } catch {
            throw error
        }
        guard await metadataExtractor.supportsImage(at: staged.stagingURL) else {
            _ = try? await blobStore.recoverStaging()
            throw OriginalReceiveError.unreadableImage(filename)
        }
        let extracted: ExtractedAssetMetadata
        do {
            extracted = try await metadataExtractor.extract(from: staged.stagingURL)
        } catch {
            _ = try? await blobStore.recoverStaging()
            throw error
        }
        var metadata = extracted.metadata
        metadata.file.filenameExtension = Self.normalizedExtension(sourceURL.pathExtension)
        let committed: CommittedBlob
        do {
            committed = try await blobStore.commit(staged)
        } catch {
            _ = try? await blobStore.recoverStaging()
            throw error
        }
        guard committed.fileSize == hash.byteCount, committed.fileSize > 0 else {
            try? await blobStore.removeNewlyCommitted(committed)
            throw OriginalReceiveError.unreadableImage(filename)
        }
        let now = Date()
        let sourceCreatedAt = try? sourceURL.resourceValues(forKeys: [.creationDateKey]).creationDate
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let displayName = baseName.isEmpty ? filename : baseName
        let asset = Asset(
            id: assetID,
            filename: filename,
            displayName: displayName,
            parentFolderID: parentFolderID,
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
        let receipt = LocalOriginalReceipt(
            filename: filename,
            asset: asset,
            disposition: .imported,
            sha256: hash.digest,
            mediaType: mediaType,
            originalExtension: Self.normalizedExtension(sourceURL.pathExtension),
            fileURL: committed.localURL
        )
        do {
            try await catalog.insertOriginal(asset, contentSHA256: hash.digest)
            return receipt
        } catch ScreenshotContentIdentityError.duplicateContent {
            try? await blobStore.removeNewlyCommitted(committed)
            guard let existingID = try await catalog.assetID(forContentSHA256: hash.digest),
                  let existing = try await catalog.asset(id: existingID) else {
                throw OriginalReceiveError.unreadableImage(filename)
            }
            return LocalOriginalReceipt(
                filename: filename,
                asset: existing,
                disposition: .alreadyPresent,
                sha256: hash.digest,
                mediaType: mediaType,
                originalExtension: receipt.originalExtension,
                fileURL: try await blobStore.resolve(existing.storageKey)
            )
        } catch {
            try? await blobStore.removeNewlyCommitted(committed)
            throw error
        }
    }

    private func destinationFolderID(for sourceURL: URL) async throws -> FolderID {
        switch space {
        case .personal:
            guard let year = OriginalReceivePlacement.personalYearName(in: sourceURL) else {
                throw OriginalReceiveError.missingSourceYear(sourceURL.lastPathComponent)
            }
            return try await catalog.ensureRootFolder(named: year)
        case .hairSolutions:
            return try await catalog.ensureRootFolder(named: OriginalReceivePlacement.hairSolutionsInboxName)
        case .screenshots:
            return catalog.inboxFolderID
        }
    }

    private struct ContentHash: Equatable {
        let digest: String
        let byteCount: Int64
    }

    static func mediaType(for pathExtension: String) -> String? {
        switch normalizedExtension(pathExtension) {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        case "webp": "image/webp"
        case "avif": "image/avif"
        default: nil
        }
    }

    private static func normalizedExtension(_ pathExtension: String) -> String {
        pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private static func imageFiles(at url: URL) throws -> [URL] {
        let source = url.standardizedFileURL
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        if values.isSymbolicLink == true { return [] }
        if values.isDirectory == true {
            let children = try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            return try children.flatMap { try imageFiles(at: $0) }.sorted { $0.path < $1.path }
        }
        guard values.isRegularFile == true, mediaType(for: source.pathExtension) != nil else { return [] }
        return [source]
    }

    private static func path(_ url: URL, isInside parent: URL) -> Bool {
        let child = url.resolvingSymlinksInPath().standardizedFileURL.path
        var parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        if child == parentPath { return true }
        if !parentPath.hasSuffix("/") { parentPath += "/" }
        return child.hasPrefix(parentPath)
    }
}

public struct LocalOriginalReceipt: Sendable {
    public let filename: String
    public let asset: Asset
    public let disposition: OriginalReceiveDisposition
    public let sha256: String
    public let mediaType: String
    public let originalExtension: String
    public let fileURL: URL

    public var byteSize: Int64 { asset.fileSize }
    public var displayName: String { asset.displayName }
}
