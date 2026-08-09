import Foundation
import FramebaseDomain
import FramebaseMigration
import Testing

@Suite("Fixture library factory", .serialized)
struct FixtureLibraryFactoryTests {
    @Test("A deterministic fixture library contains managed originals and catalog records")
    func createsFixtureLibrary() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }

        #expect(fixture.rootURL.lastPathComponent == FixtureMigrationAuthorization.fixtureLibraryDirectoryName)
        let catalogAssetCount = try await fixture.catalog.assets.count(matching: AssetQuery(scope: .allAssets))
        #expect(catalogAssetCount == 3, "Fixture catalog contains \(catalogAssetCount) assets")
        for asset in fixture.assets {
            let original = fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory)
            #expect(FileManager.default.fileExists(atPath: original.path))
        }
        _ = try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL)
    }
}
