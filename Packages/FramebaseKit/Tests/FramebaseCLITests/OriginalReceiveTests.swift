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
        let incoming = directory.appendingPathComponent("2014", isDirectory: true)
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
        let yearFolder = try #require(try await catalog.folders.treeSnapshot().folders.first {
            $0.name.rawValue == "2014" && $0.parentFolderID == nil
        })
        #expect(asset.parentFolderID == yearFolder.id)
        #expect(asset.parentFolderID != catalog.inboxID)
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

    @Test("Personal year folders come from the source path and are created when missing")
    func personalYearFoldersFollowTheSourcePath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FramebaseOriginalYears-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent(LibrarySpace.personal.packageName, isDirectory: true)
        let export = directory.appendingPathComponent("iPhoto export 2010-2026/personal", isDirectory: true)
        let year2010 = export.appendingPathComponent("2010/album", isDirectory: true)
        let year2026 = export.appendingPathComponent("2026", isDirectory: true)
        let unlabeled = export.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: year2010, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: year2026, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unlabeled, withIntermediateDirectories: true)
        let first = year2010.appendingPathComponent("early.png")
        let second = year2026.appendingPathComponent("late.png")
        let unlabeledFile = unlabeled.appendingPathComponent("loose.png")
        try writePNG(at: first)
        try writePNG(at: second, fill: 2)
        try writePNG(at: unlabeledFile, fill: 3)

        #expect(OriginalReceivePlacement.personalYearName(in: first) == "2010")
        #expect(OriginalReceivePlacement.personalYearName(in: second) == "2026")
        #expect(OriginalReceivePlacement.personalYearName(in: unlabeledFile) == nil)
        let exportNamed = directory.appendingPathComponent("iPhoto export 2010-2026/photo.png")
        #expect(OriginalReceivePlacement.personalYearName(in: exportNamed) == nil)

        let json = try await FramebaseCLI.execute(arguments: [
            "receive-originals", "--library", library.path, "--space", "personal", first.path, second.path
        ])
        let report = try JSONDecoder().decode(OriginalReceiveReport.self, from: Data(json.utf8))
        #expect(report.items.allSatisfy { $0.disposition == .imported })
        let catalog = try CatalogDatabase(catalogURL: library.appendingPathComponent("Catalog/catalog.sqlite"))
        let folders = try await catalog.folders.treeSnapshot().folders
        let folder2010 = try #require(folders.first { $0.name.rawValue == "2010" && $0.parentFolderID == nil })
        let folder2026 = try #require(folders.first { $0.name.rawValue == "2026" && $0.parentFolderID == nil })
        #expect(folders.filter { $0.name.rawValue == "2010" }.count == 1)
        #expect(!folders.contains { $0.name.rawValue.contains("iPhoto") })
        let earlyAssetID = try #require(report.items.first { $0.filename == "early.png" }?.assetID)
        let lateAssetID = try #require(report.items.first { $0.filename == "late.png" }?.assetID)
        let firstID = try #require(UUID(uuidString: earlyAssetID)).mapToAssetID()
        let secondID = try #require(UUID(uuidString: lateAssetID)).mapToAssetID()
        #expect(try await catalog.assets.asset(id: firstID)?.parentFolderID == folder2010.id)
        #expect(try await catalog.assets.asset(id: secondID)?.parentFolderID == folder2026.id)

        await #expect(throws: OriginalReceiveError.missingSourceYear("loose.png")) {
            _ = try await FramebaseCLI.execute(arguments: [
                "receive-originals", "--library", library.path, "--space", "personal", unlabeledFile.path
            ])
        }
        #expect(try await catalog.assets.count(matching: AssetQuery(scope: .allAssets)) == 2)
    }

    @Test("Hair Solutions receives into 00_inbox and does not create year folders")
    func hairSolutionsUsesInboxWithoutYears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FramebaseOriginalHSC-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent(LibrarySpace.hairSolutions.packageName, isDirectory: true)
        let source = directory.appendingPathComponent("business/2019", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("studio.png")
        try writePNG(at: file, fill: 4)

        let json = try await FramebaseCLI.execute(arguments: [
            "receive-originals", "--library", library.path, "--space", "hairSolutions", file.path
        ])
        let report = try JSONDecoder().decode(OriginalReceiveReport.self, from: Data(json.utf8))
        #expect(report.librarySpace == LibrarySpace.hairSolutions.rawValue)
        #expect(report.items.map(\.disposition) == [.imported])
        let catalog = try CatalogDatabase(catalogURL: library.appendingPathComponent("Catalog/catalog.sqlite"))
        let folders = try await catalog.folders.treeSnapshot().folders
        let inbox = try #require(folders.first { $0.name.rawValue == "00_inbox" && $0.parentFolderID == nil })
        #expect(folders.filter { $0.name.rawValue == "00_inbox" }.count == 1)
        #expect(!folders.contains { $0.name.rawValue == "2019" })
        let rawAssetID = try #require(report.items.first?.assetID)
        let assetID = try #require(UUID(uuidString: rawAssetID)).mapToAssetID()
        #expect(try await catalog.assets.asset(id: assetID)?.parentFolderID == inbox.id)
        #expect(try await catalog.assets.asset(id: assetID)?.parentFolderID != catalog.inboxID)
    }

    @Test("The production API URL is accepted only when that exact URL is passed")
    func productionAPIIsAcceptedOnlyWhenPassed() async throws {
        let approved = try #require(URL(string: "https://framebase-api-prod.notionsync.workers.dev"))
        try OriginalReceiveAPIPolicy.validate(approved)
        let refused = [
            "https://hsc-media-origin.example",
            "https://cdn.example/hsc-media-origin/object",
            "https://framebase-api-prod.example",
            "https://framebase-api-prod.notionsync.workers.dev.evil.example",
            "http://framebase-api-prod.notionsync.workers.dev",
            "https://framebase-api-prod.notionsync.workers.dev/v1",
            "https://account.r2.cloudflarestorage.com/framebase-blobs-prod/blobs/sha256/ab/hash.jpg",
            "https://framebase-catalog-prod.example"
        ]
        for raw in refused {
            let url = try #require(URL(string: raw))
            #expect(throws: OriginalReceiveError.productionTargetRefused) {
                try OriginalReceiveAPIPolicy.validate(url)
            }
        }
        try OriginalReceiveAPIPolicy.validate(try #require(URL(string: "https://framebase-api-dev.notionsync.workers.dev")))

        await #expect(throws: OriginalReceiveError.cloudCredentialsIncomplete) {
            _ = try await FramebaseCLI.execute(arguments: [
                "receive-originals",
                "--library", "/tmp/Personal Library.framebase",
                "--space", "personal",
                "--api", approved.absoluteString,
                "/tmp/photo.png"
            ])
        }
        await #expect(throws: OriginalReceiveError.productionTargetRefused) {
            _ = try await FramebaseCLI.execute(arguments: [
                "receive-originals",
                "--library", "/tmp/Personal Library.framebase",
                "--space", "personal",
                "--api", "https://hsc-media-origin.example",
                "--token", "token",
                "/tmp/photo.png"
            ])
        }
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

    private func writePNG(at url: URL, fill: UInt8 = 0) throws {
        guard let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(red: CGFloat(fill) / 255, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
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
