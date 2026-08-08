import CoreGraphics
import Foundation
import FramebaseDomain
import FramebaseMedia
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Import and metadata pipeline")
struct ImportPipelineTests {
    @Test("ImageIO validates pixels and extracts normalized image metadata")
    func extractsImageMetadata() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let imageURL = try fixture.writePNG(named: "sample.png", width: 3, height: 2)
        let invalidURL = try fixture.write(named: "broken.jpg", data: Data("not an image".utf8))
        let extractor = ImageIOMetadataExtractor()

        #expect(await extractor.supportsImage(at: imageURL))
        let extracted = try await extractor.extract(from: imageURL)
        #expect(extracted.width == 3)
        #expect(extracted.height == 2)
        #expect(extracted.metadata.image.pixelWidth == 3)
        #expect(extracted.metadata.image.pixelHeight == 2)
        #expect(extracted.metadata.file.typeIdentifier != nil)
        #expect(!(await extractor.supportsImage(at: invalidURL)))
    }

    @Test("A batch imports valid images, reports invalid siblings, and preserves sources")
    func importsValidFilesAndReportsFailures() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let validURL = try fixture.writePNG(named: "portrait.png", width: 4, height: 5)
        let validBytes = try Data(contentsOf: validURL)
        let invalidURL = try fixture.write(named: "notes.jpg", data: Data("invalid".utf8))
        let store = try fixture.makeStore()
        let recorder = AssetRecorder()
        let coordinator = ManagedImportCoordinator(
            blobStore: store,
            metadataExtractor: ImageIOMetadataExtractor(),
            insertIntoCatalog: { assets in await recorder.insert(assets) }
        )

        let result = try await coordinator.importAssets(
            ImportRequest(sourceURLs: [validURL, invalidURL], destinationFolderID: FolderID())
        ) { _ in }

        #expect(result.importedAssetIDs.count == 1)
        #expect(result.failures.count == 1)
        #expect(!result.cancelled)
        let assets = await recorder.assets
        #expect(assets.count == 1)
        #expect(assets.first?.width == 4)
        #expect(assets.first?.height == 5)
        #expect(assets.first?.filename == "portrait.png")
        #expect(try Data(contentsOf: validURL) == validBytes)
        if let key = assets.first?.storageKey {
            #expect(await store.validate(key))
        }
    }

    @Test("Catalog failure removes only newly committed managed copies")
    func rollsBackWhenCatalogInsertFails() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let imageURL = try fixture.writePNG(named: "rollback.png", width: 2, height: 2)
        let store = try fixture.makeStore()
        let coordinator = ManagedImportCoordinator(
            blobStore: store,
            metadataExtractor: ImageIOMetadataExtractor(),
            insertIntoCatalog: { _ in throw FixtureError.catalogRejected }
        )

        do {
            _ = try await coordinator.importAssets(
                ImportRequest(sourceURLs: [imageURL], destinationFolderID: FolderID())
            ) { _ in }
            Issue.record("Expected the catalog transaction to fail")
        } catch let error as ManagedImportCoordinatorError {
            guard case .catalogCommitFailed = error else {
                Issue.record("Unexpected import error: \(error)")
                return
            }
        }

        let regularFiles = fixture.regularFiles(in: fixture.originals)
        #expect(regularFiles.isEmpty)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
    }

    @Test("Cancellation clears staging and commits no catalog records")
    func cancelsBatch() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let imageURL = try fixture.writePNG(named: "cancel.png", width: 2, height: 2)
        let store = try fixture.makeStore()
        let recorder = AssetRecorder()
        let coordinator = ManagedImportCoordinator(
            blobStore: store,
            metadataExtractor: ImageIOMetadataExtractor(),
            insertIntoCatalog: { assets in await recorder.insert(assets) }
        )

        let result = try await coordinator.importAssets(
            ImportRequest(sourceURLs: [imageURL], destinationFolderID: FolderID())
        ) { progress in
            if progress.currentFilename != nil {
                await coordinator.cancelCurrentImport()
            }
        }

        #expect(result.cancelled)
        #expect(result.importedAssetIDs.isEmpty)
        #expect(await recorder.assets.isEmpty)
        #expect(fixture.regularFiles(in: fixture.originals).isEmpty)
        #expect(fixture.regularFiles(in: fixture.staging).isEmpty)
    }

    @Test("Thumbnail provider downscales, persists, reloads, and clears derived data")
    func generatesAndCachesThumbnail() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writePNG(named: "large.png", width: 400, height: 200)
        let store = try fixture.makeStore()
        let assetID = AssetID()
        let committed = try await store.commit(store.stage(sourceURL: sourceURL, for: assetID))
        let fingerprint = AssetFingerprint(
            assetID: assetID,
            fileSize: committed.fileSize,
            modifiedAtMilliseconds: Int64(committed.modifiedAt.timeIntervalSince1970 * 1_000)
        )
        let request = ThumbnailRequest(
            storageKey: committed.storageKey,
            fingerprint: fingerprint,
            target: ThumbnailTarget(width: 100, height: 100, displayScale: 2)
        )
        let firstProvider = try ImageIOThumbnailProvider(
            blobStore: store,
            cacheDirectoryURL: fixture.cache,
            memoryCacheByteLimit: 1_024 * 1_024,
            diskCacheByteLimit: 2 * 1_024 * 1_024
        )

        let first = try await firstProvider.thumbnail(for: request)
        #expect(first.pixelWidth == 200)
        #expect(first.pixelHeight == 100)
        #expect(!first.encodedData.isEmpty)
        #expect(!fixture.regularFiles(in: fixture.cache).isEmpty)

        let reopenedProvider = try ImageIOThumbnailProvider(
            blobStore: store,
            cacheDirectoryURL: fixture.cache,
            memoryCacheByteLimit: 1_024 * 1_024,
            diskCacheByteLimit: 2 * 1_024 * 1_024
        )
        let cached = try await reopenedProvider.thumbnail(for: request)
        #expect(cached.encodedData == first.encodedData)

        try await reopenedProvider.clearDerivedCache()
        #expect(fixture.regularFiles(in: fixture.cache).isEmpty)
    }

    @Test("A cancelled thumbnail request does not decode")
    func cancelsThumbnailRequest() async throws {
        let fixture = try ImportFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writePNG(named: "cancel-thumb.png", width: 20, height: 20)
        let store = try fixture.makeStore()
        let assetID = AssetID()
        let committed = try await store.commit(store.stage(sourceURL: sourceURL, for: assetID))
        let request = ThumbnailRequest(
            storageKey: committed.storageKey,
            fingerprint: AssetFingerprint(
                assetID: assetID,
                fileSize: committed.fileSize,
                modifiedAtMilliseconds: Int64(committed.modifiedAt.timeIntervalSince1970 * 1_000)
            ),
            target: ThumbnailTarget(width: 10, height: 10, displayScale: 1)
        )
        let provider = try ImageIOThumbnailProvider(
            blobStore: store,
            cacheDirectoryURL: fixture.cache
        )
        await provider.cancel(requestID: request.id)

        await #expect(throws: CancellationError.self) {
            _ = try await provider.thumbnail(for: request)
        }
    }
}

private actor AssetRecorder {
    private(set) var assets: [Asset] = []

    func insert(_ assets: [Asset]) {
        self.assets.append(contentsOf: assets)
    }
}

private enum FixtureError: Error {
    case catalogRejected
}

private struct ImportFixture {
    let root: URL
    let sources: URL
    let originals: URL
    let staging: URL
    let cache: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseImportTests-\(UUID().uuidString)", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        originals = root.appendingPathComponent("Originals", isDirectory: true)
        staging = root.appendingPathComponent("Staging", isDirectory: true)
        cache = root.appendingPathComponent("Cache", isDirectory: true)
        for directory in [sources, originals, staging, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func makeStore() throws -> ManagedAssetBlobStore {
        try ManagedAssetBlobStore(
            originalsDirectoryURL: originals,
            stagingDirectoryURL: staging
        )
    }

    func write(named name: String, data: Data) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    func writePNG(named name: String, width: Int, height: Int) throws -> URL {
        let bytesPerRow = width * 4
        let pixels = Data(repeating: 0x7f, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw FixtureError.catalogRejected
        }

        let url = sources.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.catalogRejected
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.catalogRejected
        }
        return url
    }

    func regularFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let url = value as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    func remove() {
        guard root.lastPathComponent.hasPrefix("FramebaseImportTests-") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
