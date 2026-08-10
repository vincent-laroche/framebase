import Foundation
import FramebaseCatalog
import FramebaseCLI
import FramebaseDomain
import FramebaseTestSupport
import Testing

@Suite("Framebase local CLI")
struct FramebaseCLITests {
    @Test("Read-only diagnostics, folders, and search return machine-readable catalog metadata")
    func readOnlyCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FramebaseCLITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogURL = directory.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
        let catalog = try CatalogDatabase(catalogURL: catalogURL)
        let folder = try await catalog.folders.createFolder(named: FolderName("Reference"), in: nil)
        let asset = try FixtureFactory.asset(parentFolderID: folder.id, filename: "reference.jpg")
        try await catalog.insertAsset(asset)

        let diagnostics = try await FramebaseCLI.execute(arguments: ["diagnostics", "--catalog", catalogURL.path])
        #expect(diagnostics.contains("\"assetCount\" : 1"))
        #expect(!diagnostics.contains(catalogURL.path))

        let folders = try await FramebaseCLI.execute(arguments: ["list-folders", "--catalog", catalogURL.path])
        #expect(folders.contains("Reference"))

        let search = try await FramebaseCLI.execute(arguments: ["search", "--catalog", catalogURL.path, "--text", "reference"])
        #expect(search.contains("reference.jpg"))
        #expect(!search.contains("storageKey"))
    }

    @Test("CLI rejects missing or unsafe command shapes")
    func rejectsUnsupportedCommands() async throws {
        await #expect(throws: FramebaseCLIError.self) {
            _ = try await FramebaseCLI.execute(arguments: ["permanent-purge", "--catalog", "/tmp/catalog.sqlite"])
        }
        await #expect(throws: FramebaseCLIError.self) {
            _ = try await FramebaseCLI.execute(arguments: ["search", "--catalog", "/tmp/catalog.sqlite"])
        }
        #expect(try await FramebaseCLI.execute(arguments: ["--help"]).contains("read-only"))
    }
}
