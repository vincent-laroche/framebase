import CoreGraphics
import CoreText
import Foundation
import FramebaseCatalog
import FramebaseCLI
import FramebaseDomain
import FramebaseMedia
import ImageIO
import Testing

@Suite("Screenshot intake")
struct ScreenshotIntakeTests {
    @Test("A dropped screenshot becomes one Screenshots asset with OCR text, and a second drop does not duplicate it")
    func droppedScreenshotIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FramebaseScreenshotIntake-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("Screenshots Library.framebase", isDirectory: true)
        let inbox = directory.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let first = inbox.appendingPathComponent("one.png")
        let second = inbox.appendingPathComponent("two.png")
        try writeTextPNG(at: first, text: "FRAMEBASE")
        try FileManager.default.copyItem(at: first, to: second)

        let firstJSON = try await FramebaseCLI.execute(arguments: [
            "ingest-screenshots", "--library", library.path, "--inbox", inbox.path
        ])
        let firstReport = try JSONDecoder().decode(ScreenshotIntakeReport.self, from: Data(firstJSON.utf8))
        #expect(firstReport.librarySpace == LibrarySpace.screenshots.rawValue)
        #expect(firstReport.failureFilenames.isEmpty)
        #expect(Set(firstReport.items.map(\.filename)) == ["one.png", "two.png"])
        #expect(firstReport.items.filter { $0.disposition == .imported }.count == 1)
        #expect(firstReport.items.filter { $0.disposition == .alreadyPresent }.count == 1)
        let assetID = try #require(firstReport.items.first?.assetID)
        #expect(firstReport.items.allSatisfy { $0.assetID == assetID && $0.recognizedText.localizedCaseInsensitiveContains("FRAMEBASE") })
        #expect(!firstJSON.contains("Originals"))
        #expect(!firstJSON.contains(library.path))
        #expect(!firstJSON.contains("storageKey"))

        let catalog = try CatalogDatabase(catalogURL: library.appendingPathComponent("Catalog/catalog.sqlite"))
        let parsedID = try #require(UUID(uuidString: assetID)).mapToAssetID()
        #expect(try await catalog.librarySpace() == .screenshots)
        #expect(try await catalog.assets.count(matching: AssetQuery(scope: .allAssets)) == 1)
        let asset = try #require(try await catalog.assets.asset(id: parsedID))
        #expect(asset.parentFolderID == catalog.inboxID)
        let results = try await catalog.intelligence.results(for: parsedID)
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.kind == .ocr && $0.status == .succeeded })
        #expect(try await catalog.intelligence.assetIDsMatchingOCR("FRAMEBASE") == [parsedID])
        #expect(regularFiles(under: library.appendingPathComponent("Originals")).count == 1)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))

        let secondJSON = try await FramebaseCLI.execute(arguments: [
            "ingest-screenshots", "--library", library.path, "--inbox", inbox.path
        ])
        let secondReport = try JSONDecoder().decode(ScreenshotIntakeReport.self, from: Data(secondJSON.utf8))
        #expect(secondReport.failureFilenames.isEmpty)
        #expect(secondReport.items.allSatisfy { $0.assetID == assetID && $0.disposition == .alreadyPresent })
        #expect(secondReport.items.allSatisfy { $0.recognizedText.localizedCaseInsensitiveContains("FRAMEBASE") })
        let reopened = try CatalogDatabase(catalogURL: catalog.catalogURL)
        #expect(try await reopened.assets.count(matching: AssetQuery(scope: .allAssets)) == 1)
        #expect(try await reopened.assets.asset(id: parsedID) != nil)
        #expect(regularFiles(under: library.appendingPathComponent("Originals")).count == 1)
        #expect(try await reopened.intelligence.results(for: parsedID).allSatisfy { $0.kind == .ocr })
    }

    @Test("Personal, Hair Solutions, and other libraries refuse screenshot intake")
    func otherLibrariesStayEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FramebaseScreenshotRefusal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(LibrarySpace?, String)] = [
            (.personal, LibrarySpace.personal.packageName),
            (.hairSolutions, LibrarySpace.hairSolutions.packageName),
            (nil, "Other Library.framebase")
        ]
        for (space, packageName) in cases {
            let root = directory.appendingPathComponent(packageName, isDirectory: true)
            let package = try ScreenshotLibraryPackage(rootURL: root)
            try package.prepare()
            let catalog = try CatalogDatabase(catalogURL: package.catalogDatabaseURL)
            if let space {
                try await catalog.assignLibrarySpace(space)
            }
            let inbox = directory.appendingPathComponent("inbox-\(packageName)", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let file = inbox.appendingPathComponent("shot.png")
            try Data("not-a-real-screenshot".utf8).write(to: file)

            await #expect(throws: ScreenshotIntakeError.notScreenshotsLibrary) {
                _ = try await FramebaseCLI.execute(arguments: [
                    "ingest-screenshots", "--library", root.path, "--inbox", inbox.path
                ])
            }

            let reopened = try CatalogDatabase(catalogURL: package.catalogDatabaseURL)
            #expect(try await reopened.librarySpace() == space)
            #expect(try await reopened.assets.count(matching: AssetQuery(scope: .allAssets)) == 0)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(regularFiles(under: package.originalsDirectoryURL).isEmpty)
        }
    }

    @Test("An inbox inside the library package is refused before any copy")
    func inboxInsideTheLibraryIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FramebaseScreenshotOverlap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("Screenshots Library.framebase", isDirectory: true)
        let inbox = library.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("shot.png")
        try Data("leave-me".utf8).write(to: file)

        await #expect(throws: ScreenshotIntakeError.inboxOverlapsLibrary) {
            _ = try await FramebaseCLI.execute(arguments: [
                "ingest-screenshots", "--library", library.path, "--inbox", inbox.path
            ])
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("Catalog/catalog.sqlite").path))
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

    private func writeTextPNG(at url: URL, text: String) throws {
        let width = 2_400
        let height = 900
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 230, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 160, y: 330)
        CTLineDraw(line, context)
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
