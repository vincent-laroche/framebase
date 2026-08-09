import Foundation
import FramebaseDomain
import FramebaseMigration
import Testing

@Suite("Migration manifest", .serialized)
struct MigrationManifestStoreTests {
    @Test("A completed fixture entry persists across a manifest reopen")
    func completedEntrySurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FramebaseManifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "migration.sqlite", directoryHint: .notDirectory)
        let assetID = AssetID()
        let entry = MigrationManifestEntry(
            assetID: assetID,
            storageKey: "ab/\(assetID.description).jpg",
            byteSize: 1_024,
            sha256: String(repeating: "a", count: 64),
            remoteBlobID: String(repeating: "a", count: 64),
            remoteAssetID: assetID.description,
            state: .registered,
            retryCount: 1,
            lastError: nil
        )

        let first = try MigrationManifestStore(databaseURL: databaseURL)
        try await first.upsert(entry)
        let reopened = try MigrationManifestStore(databaseURL: databaseURL)

        #expect(try await reopened.entry(for: assetID) == entry)
    }
}
