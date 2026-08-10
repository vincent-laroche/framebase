import Foundation
import FramebaseDomain
import FramebaseMedia
import Testing

@Suite("Verified asset export")
struct AssetExporterTests {
    @Test("Export copies managed originals and emits a complete hashed manifest")
    func exportsManagedOriginalWithoutMutatingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FramebaseExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        let destination = root.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let sourceData = Data((0..<8_192).map { UInt8($0 % 251) })
        let sourceURL = sources.appendingPathComponent("portrait.jpg")
        try sourceData.write(to: sourceURL)
        let store = try ManagedAssetBlobStore(originalsDirectoryURL: originals, stagingDirectoryURL: staging)
        let assetID = AssetID()
        let committed = try await store.commit(store.stage(sourceURL: sourceURL, for: assetID))
        let asset = Asset(
            id: assetID,
            filename: "portrait.jpg",
            displayName: "Portrait",
            parentFolderID: FolderID(),
            storageKey: committed.storageKey,
            fileSize: committed.fileSize,
            createdAt: .now,
            modifiedAt: committed.modifiedAt,
            importedAt: .now,
            updatedAt: .now
        )

        let result = try await AssetExporter(blobStore: store).export([asset], to: destination)
        let manifestFiles = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(manifestFiles.count == 2)
        #expect(result.manifest.assets.count == 1)
        #expect(result.receipt.assetIDs == [assetID])
        #expect(result.receipt.manifestSHA256.count == 64)
        let outputURL = try #require(manifestFiles.first { $0.lastPathComponent.hasSuffix("-portrait.jpg") })
        #expect(try Data(contentsOf: outputURL) == sourceData)
        #expect(try Data(contentsOf: committed.localURL) == sourceData)
        let manifestURL = try #require(manifestFiles.first { $0.lastPathComponent.hasSuffix(".manifest.json") })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AssetExportManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.assets.first?.assetID == assetID)
    }
}
