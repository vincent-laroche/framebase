import CoreGraphics
import Foundation
import FramebaseCatalog
import FramebaseCLI
import FramebaseDomain
import FramebaseMedia
import ImageIO
import Testing

@Suite("Original receive")
struct OriginalReceiveTests {
    @Test("The same original becomes one Personal asset, and a second receive does not duplicate it")
    func personalOriginalIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FramebaseOriginalReceive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent(LibrarySpace.personal.packageName, isDirectory: true)
        let screenshots = directory.appendingPathComponent(LibrarySpace.screenshots.packageName, isDirectory: true)
        let incoming = directory.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let screenshotsPackage = try FramebaseLibraryPackage(rootURL: screenshots)
        try screenshotsPackage.prepare()
        let screenshotsCatalog = try CatalogDatabase(catalogURL: screenshotsPackage.catalogDatabaseURL)
        try await screenshotsCatalog.assignLibrarySpace(.screenshots)

        let first = incoming.appendingPathComponent("one.png")
        let second = incoming.appendingPathComponent("two.png")
        try writePNG(at: first)
        try FileManager.default.copyItem(at: first, to: second)

        let firstJSON = try await FramebaseCLI.execute(arguments: [
            "receive-originals", "--library", library.path, "--space", "personal", first.path, second.path
        ])
        let firstReport = try JSONDecoder().decode(OriginalReceiveReport.self, from: Data(firstJSON.utf8))
        #expect(firstReport.librarySpace == LibrarySpace.personal.rawValue)
        #expect(firstReport.bucket == "local")
        #expect(firstReport.failureFilenames.isEmpty)
        #expect(Set(firstReport.items.map(\.filename)) == ["one.png", "two.png"])
        #expect(firstReport.items.filter { $0.disposition == .imported }.count == 1)
        #expect(firstReport.items.filter { $0.disposition == .alreadyPresent }.count == 1)
        #expect(firstReport.items.allSatisfy { $0.blob == .localOnly })
        let assetID = try #require(firstReport.items.first?.assetID)
        #expect(firstReport.items.allSatisfy { $0.assetID == assetID })
        #expect(!firstJSON.contains("Originals"))
        #expect(!firstJSON.contains(library.path))
        #expect(!firstJSON.contains("storageKey"))
        #expect(!firstJSON.contains("X-Amz-"))
        #expect(!firstJSON.contains("r2.cloudflarestorage.com"))

        let catalog = try CatalogDatabase(catalogURL: library.appendingPathComponent("Catalog/catalog.sqlite"))
        #expect(try await catalog.librarySpace() == .personal)
        #expect(try await catalog.assets.count(matching: AssetQuery(scope: .allAssets)) == 1)
        let parsedID = try #require(UUID(uuidString: assetID)).mapToAssetID()
        let asset = try #require(try await catalog.assets.asset(id: parsedID))
        #expect(asset.parentFolderID == catalog.inboxID)
        #expect(regularFiles(under: library.appendingPathComponent("Originals")).count == 1)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(try await screenshotsCatalog.assets.count(matching: AssetQuery(scope: .allAssets)) == 0)

        let secondJSON = try await FramebaseCLI.execute(arguments: [
            "receive-originals", "--library", library.path, "--space", "personal", incoming.path
        ])
        let secondReport = try JSONDecoder().decode(OriginalReceiveReport.self, from: Data(secondJSON.utf8))
        #expect(secondReport.failureFilenames.isEmpty)
        #expect(secondReport.items.allSatisfy { $0.assetID == assetID && $0.disposition == .alreadyPresent && $0.blob == .localOnly })
        let reopened = try CatalogDatabase(catalogURL: catalog.catalogURL)
        #expect(try await reopened.assets.count(matching: AssetQuery(scope: .allAssets)) == 1)
        #expect(regularFiles(under: library.appendingPathComponent("Originals")).count == 1)
    }

    @Test("Screenshots are not received into the Personal library")
    func wrongSpaceStaysEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FramebaseOriginalSpace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent(LibrarySpace.personal.packageName, isDirectory: true)
        let package = try FramebaseLibraryPackage(rootURL: library)
        try package.prepare()
        let catalog = try CatalogDatabase(catalogURL: package.catalogDatabaseURL)
        try await catalog.assignLibrarySpace(.personal)
        let file = directory.appendingPathComponent("shot.png")
        try writePNG(at: file)

        await #expect(throws: OriginalReceiveError.librarySpaceMismatch(existing: .personal, requested: .screenshots)) {
            _ = try await FramebaseCLI.execute(arguments: [
                "receive-originals", "--library", library.path, "--space", "screenshots", file.path
            ])
        }
        let reopened = try CatalogDatabase(catalogURL: package.catalogDatabaseURL)
        #expect(try await reopened.assets.count(matching: AssetQuery(scope: .allAssets)) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(regularFiles(under: package.originalsDirectoryURL).isEmpty)
    }

    private func regularFiles(under url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }
    }

    private func writePNG(at url: URL) throws {
        guard let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

private extension UUID {
    func mapToAssetID() -> AssetID { AssetID(rawValue: self) }
}
