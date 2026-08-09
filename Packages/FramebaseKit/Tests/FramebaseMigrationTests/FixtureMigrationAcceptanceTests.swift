import Foundation
import FramebaseAPIClient
import FramebaseDomain
import FramebaseMigration
import Testing

@Suite("Fixture migration acceptance", .serialized)
struct FixtureMigrationAcceptanceTests {
    @Test("Fixture manifest restore drill rebuilds relationships and reports a missing original")
    func fixtureManifestRestoreDrill() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let authorization = try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL)

        let manifestURL = try await FixtureLibraryManifestService.export(
            authorization: authorization,
            catalog: fixture.catalog
        )
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        let cleanReport = try await FixtureLibraryManifestService.restoreDrill(authorization: authorization)
        #expect(cleanReport.isSuccessful)
        #expect(cleanReport.parity.isEquivalent)
        #expect(cleanReport.missingOriginalAssetIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: cleanReport.rebuiltCatalogURL.path))

        let missingAsset = try #require(fixture.assets.last)
        try FileManager.default.removeItem(
            at: fixture.originalsURL.appending(path: missingAsset.storageKey.rawValue, directoryHint: .notDirectory)
        )
        let missingReport = try await FixtureLibraryManifestService.restoreDrill(authorization: authorization)
        #expect(missingReport.missingOriginalAssetIDs == [missingAsset.id])
        #expect(!missingReport.isSuccessful)
    }

    @Test("A deterministic 5,000-asset fixture preserves local bytes, keys, and remote asset/blob parity")
    func migratesFiveThousandAssetsWithParity() async throws {
        let fixture = try await FixtureLibraryFactory().create(assetCount: 5_000)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL.deletingLastPathComponent()) }
        let authorization = try FixtureMigrationAuthorization.fixtureOnly(rootURL: fixture.rootURL)
        let manifest = try MigrationManifestStore(databaseURL: fixture.rootURL.appending(path: "Sync/migration.sqlite", directoryHint: .notDirectory))
        let api = InMemoryMigrationAPIClient()
        let digestService = FileDigestService()
        var originals: [AssetID: (storageKey: String, bytes: Data, digest: FileDigest)] = [:]
        for asset in fixture.assets {
            let originalURL = fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory)
            originals[asset.id] = (asset.storageKey.rawValue, try Data(contentsOf: originalURL), try await digestService.digest(at: originalURL))
        }
        let coordinator = FixtureMigrationCoordinator(
            authorization: authorization,
            catalog: fixture.catalog,
            originalsURL: fixture.originalsURL,
            manifest: manifest,
            apiClient: api,
            digestService: digestService
        )

        let report = try await coordinator.run()

        #expect(report.registeredAssetIDs.count == fixture.assets.count)
        #expect(api.registrations.count == fixture.assets.count)
        var remoteAssets: [FixtureRemoteAsset] = []
        var remoteBlobs: [Blob] = []
        for asset in fixture.assets {
            let expected = try #require(originals[asset.id])
            let remote = try #require(api.registrations[asset.id.description])
            #expect(remote.assetId == asset.id.description)
            #expect(remote.blobId == expected.digest.sha256)
            #expect(remote.folderId == asset.parentFolderID.description)
            #expect(remote.filename == asset.filename)
            #expect(remote.displayName == asset.displayName)
            #expect(remote.favorite == asset.favorite)
            #expect(remote.rating == asset.rating.rawValue)
            #expect(api.uploadedData(blobID: expected.digest.sha256) == expected.bytes)
            #expect(try await fixture.catalog.blobs.blobSHA256(for: asset.id) == expected.digest.sha256)
            #expect(asset.storageKey.rawValue == expected.storageKey)
            #expect(try Data(contentsOf: fixture.originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory)) == expected.bytes)
            let metadata = try JSONDecoder().decode(AssetMetadata.self, from: JSONEncoder().encode(remote.metadata))
            remoteAssets.append(FixtureRemoteAsset(
                id: asset.id,
                blobSHA256: remote.blobId,
                folderID: asset.parentFolderID,
                filename: remote.filename,
                displayName: remote.displayName,
                width: remote.width,
                height: remote.height,
                createdAt: try #require(ISO8601Coding.parse(remote.createdAt)),
                modifiedAt: try #require(ISO8601Coding.parse(remote.modifiedAt)),
                importedAt: try #require(ISO8601Coding.parse(remote.importedAt)),
                favorite: remote.favorite,
                rating: try AssetRating(remote.rating),
                metadata: metadata
            ))
            remoteBlobs.append(try #require(try await fixture.catalog.blobs.blob(sha256: expected.digest.sha256)))
        }
        let rebuiltCatalogURL = fixture.rootURL.appending(path: "Rebuilt/catalog.sqlite", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: rebuiltCatalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rebuilt = try await FixtureParityVerifier.rebuildCatalog(
            from: FixtureRemoteCatalogSnapshot(folders: fixture.folders, blobs: remoteBlobs, assets: remoteAssets),
            at: rebuiltCatalogURL
        )
        let parity = try await FixtureParityVerifier.compare(
            sourceAssets: fixture.assets,
            sourceBlobSHA256: Dictionary(uniqueKeysWithValues: originals.map { ($0.key, $0.value.digest.sha256) }),
            rebuiltCatalog: rebuilt
        )
        #expect(parity.isEquivalent)
    }
}
