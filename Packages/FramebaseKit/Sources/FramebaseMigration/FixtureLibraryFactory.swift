import Foundation
import FramebaseCatalog
import FramebaseDomain

public struct FixtureLibrary: Sendable {
    public let rootURL: URL
    public let originalsURL: URL
    public let catalog: CatalogDatabase
    public let folders: [Folder]
    public let assets: [Asset]
}

/// Creates only deterministic temporary libraries for migration tests. The
/// fixture root is intentionally distinct from any user library name.
public actor FixtureLibraryFactory {
    public init() {}

    public func create(assetCount: Int) async throws -> FixtureLibrary {
        precondition(assetCount >= 0)
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "FramebaseFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = parent.appending(path: FixtureMigrationAuthorization.fixtureLibraryDirectoryName, directoryHint: .isDirectory)
        let originals = root.appending(path: "Originals", directoryHint: .isDirectory)
        let catalogDirectory = root.appending(path: "Catalog", directoryHint: .isDirectory)
        let syncDirectory = root.appending(path: "Sync", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        let catalog = try CatalogDatabase(catalogURL: catalogDirectory.appending(path: "catalog.sqlite", directoryHint: .notDirectory))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fixtureFolder = try await catalog.folders.createFolder(
            id: FolderID(rawValue: UUID(uuidString: "00000000-0000-0000-ffff-000000000001")!),
            named: try FolderName("Fixture Assets"),
            in: nil
        )
        var assets: [Asset] = []
        assets.reserveCapacity(assetCount)
        for index in 0..<assetCount {
            let uuidText = String(format: "00000000-0000-0000-0000-%012x", index + 1)
            let assetID = AssetID(rawValue: UUID(uuidString: uuidText)!)
            let key = try AssetStorageKey("\(String(assetID.description.prefix(2)))/\(assetID.description).jpg")
            let fileURL = originals.appending(path: key.rawValue, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture-original-\(index)".utf8).write(to: fileURL, options: .atomic)
            let byteSize = Int64((try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
            assets.append(Asset(id: assetID, filename: "fixture-\(index).jpg", displayName: "Fixture \(index)", parentFolderID: fixtureFolder.id, storageKey: key, fileSize: byteSize, createdAt: date, modifiedAt: date, importedAt: date, updatedAt: date))
        }
        try await catalog.insertAssets(assets)
        return FixtureLibrary(rootURL: root, originalsURL: originals, catalog: catalog, folders: [fixtureFolder], assets: assets)
    }
}
