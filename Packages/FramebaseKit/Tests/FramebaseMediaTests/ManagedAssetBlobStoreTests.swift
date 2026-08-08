import Foundation
import FramebaseDomain
import FramebaseMedia
import Testing

@Suite("Managed original storage")
struct ManagedAssetBlobStoreTests {
    @Test("Initialization safely prepares explicit sibling directories")
    func preparesDirectories() throws {
        let fixture = try Fixture(createManagedDirectories: false)
        defer { fixture.remove() }

        _ = try ManagedAssetBlobStore(
            originalsDirectoryURL: fixture.originals,
            stagingDirectoryURL: fixture.staging
        )

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fixture.originals.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: fixture.staging.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("Staging and commit preserve source bytes and use an immutable sharded key")
    func stagesAndCommitsWithoutMutatingSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.writeSource(named: "Portrait.HEIC", data: Self.sampleBytes)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let assetID = AssetID(rawValue: UUID(uuidString: "a13f20d7-96a4-4b24-a921-bdf110469a41")!)
        let store = try fixture.makeStore()

        let staged = try await store.stage(sourceURL: source, for: assetID)
        #expect(staged.preferredFilenameExtension == "HEIC")
        #expect(staged.stagingURL.deletingLastPathComponent() == fixture.staging)
        #expect(FileManager.default.fileExists(atPath: staged.stagingURL.path))
        #expect(try Data(contentsOf: staged.stagingURL) == Self.sampleBytes)
        #expect(try Data(contentsOf: source) == Self.sampleBytes)

        let committed = try await store.commit(staged)
        #expect(committed.storageKey.rawValue == "a1/a13f20d7-96a4-4b24-a921-bdf110469a41.HEIC")
        #expect(committed.localURL == fixture.originals.appendingPathComponent(committed.storageKey.rawValue))
        #expect(!FileManager.default.fileExists(atPath: staged.stagingURL.path))
        #expect(try Data(contentsOf: committed.localURL) == Self.sampleBytes)
        #expect(try Data(contentsOf: source) == Self.sampleBytes)
        #expect(committed.fileSize == Int64(Self.sampleBytes.count))

        let currentAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect((originalAttributes[.size] as? NSNumber) == (currentAttributes[.size] as? NSNumber))
        #expect((originalAttributes[.modificationDate] as? Date) == (currentAttributes[.modificationDate] as? Date))
    }

    @Test("A reopened store resolves valid keys and rejects malformed or missing keys")
    func reopensResolvesAndValidatesStrictly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.writeSource(named: "image.png", data: Self.sampleBytes)
        let assetID = AssetID(rawValue: UUID(uuidString: "09c47f0e-bc6b-43a7-b6e1-414b1d6b4b78")!)
        let firstStore = try fixture.makeStore()
        let committed = try await firstStore.commit(firstStore.stage(sourceURL: source, for: assetID))

        let reopenedStore = try fixture.makeStore()
        #expect(try await reopenedStore.resolve(committed.storageKey) == committed.localURL)
        #expect(await reopenedStore.validate(committed.storageKey))

        let malformed = try AssetStorageKey("09/not-a-uuid.png")
        await expectError(.invalidStorageKey(malformed.rawValue)) {
            _ = try await reopenedStore.resolve(malformed)
        }
        #expect(!(await reopenedStore.validate(malformed)))

        let missing = try AssetStorageKey("ff/ffffffff-ffff-4fff-8fff-ffffffffffff.png")
        await expectError(.managedBlobMissing(missing)) {
            _ = try await reopenedStore.resolve(missing)
        }
        #expect(!(await reopenedStore.validate(missing)))
    }

    @Test("Rollback removes only a copy newly committed by the same store instance")
    func rollbackIsCapabilityScoped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.writeSource(named: "rollback.jpg", data: Self.sampleBytes)
        let store = try fixture.makeStore()
        let committed = try await store.commit(store.stage(sourceURL: source, for: AssetID()))

        let reopenedStore = try fixture.makeStore()
        await expectError(.rollbackNotPermitted(committed.storageKey)) {
            try await reopenedStore.removeNewlyCommitted(committed)
        }
        #expect(FileManager.default.fileExists(atPath: committed.localURL.path))

        try await store.removeNewlyCommitted(committed)
        #expect(!FileManager.default.fileExists(atPath: committed.localURL.path))
        #expect(!(await store.validate(committed.storageKey)))
        #expect(try Data(contentsOf: source) == Self.sampleBytes)

        await expectError(.rollbackNotPermitted(committed.storageKey)) {
            try await store.removeNewlyCommitted(committed)
        }
    }

    @Test("Recovery removes abandoned regular staging files and reports unexpected entries")
    func recoversAbandonedStagingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let abandonedOne = fixture.staging.appendingPathComponent("one.stage")
        let abandonedTwo = fixture.staging.appendingPathComponent("two.stage")
        let unexpectedDirectory = fixture.staging.appendingPathComponent("unexpected", isDirectory: true)
        try Data([1]).write(to: abandonedOne)
        try Data([2]).write(to: abandonedTwo)
        try FileManager.default.createDirectory(at: unexpectedDirectory, withIntermediateDirectories: false)
        let store = try fixture.makeStore()

        let result = try await store.recoverStaging()
        #expect(result.recoveredCount == 2)
        #expect(result.failedURLs == [unexpectedDirectory])
        #expect(!FileManager.default.fileExists(atPath: abandonedOne.path))
        #expect(!FileManager.default.fileExists(atPath: abandonedTwo.path))
        #expect(FileManager.default.fileExists(atPath: unexpectedDirectory.path))
    }

    @Test("Existing UUID storage prevents overwrite even when a new extension differs")
    func rejectsManagedCollisionsWithoutChangingEitherSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstBytes = Data("first original".utf8)
        let secondBytes = Data("second original".utf8)
        let firstSource = try fixture.writeSource(named: "first.jpg", data: firstBytes)
        let secondSource = try fixture.writeSource(named: "second.png", data: secondBytes)
        let assetID = AssetID()
        let store = try fixture.makeStore()
        let firstCommit = try await store.commit(store.stage(sourceURL: firstSource, for: assetID))
        let secondStage = try await store.stage(sourceURL: secondSource, for: assetID)

        await expectError(.managedAssetAlreadyExists(assetID)) {
            _ = try await store.commit(secondStage)
        }

        #expect(try Data(contentsOf: firstCommit.localURL) == firstBytes)
        #expect(try Data(contentsOf: firstSource) == firstBytes)
        #expect(try Data(contentsOf: secondSource) == secondBytes)
        #expect(FileManager.default.fileExists(atPath: secondStage.stagingURL.path))
        let recovery = try await store.recoverStaging()
        #expect(recovery.recoveredCount == 1)
    }

    @Test("Unsafe sources, forged staging values, and overlapping roots are rejected")
    func rejectsUnsafeInputs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unsafeExtensionSource = try fixture.writeSource(named: "image.bad-ext", data: Self.sampleBytes)
        let store = try fixture.makeStore()

        await expectError(.unsafeFilenameExtension("bad-ext")) {
            _ = try await store.stage(sourceURL: unsafeExtensionSource, for: AssetID())
        }

        let forgedURL = fixture.staging.appendingPathComponent("forged.stage")
        try Self.sampleBytes.write(to: forgedURL)
        let forged = StagedBlob(
            assetID: AssetID(),
            sourceURL: unsafeExtensionSource,
            stagingURL: forgedURL,
            preferredFilenameExtension: "jpg"
        )
        await expectError(.unrecognizedStagedBlob) {
            _ = try await store.commit(forged)
        }

        #expect(throws: ManagedAssetBlobStoreError.unsafeDirectoryRelationship) {
            _ = try ManagedAssetBlobStore(
                originalsDirectoryURL: fixture.originals,
                stagingDirectoryURL: fixture.originals.appendingPathComponent("nested", isDirectory: true)
            )
        }
    }

    private static let sampleBytes = Data((0..<4_096).map { UInt8($0 % 251) })
}

private struct Fixture {
    let root: URL
    let originals: URL
    let staging: URL
    let sources: URL

    init(createManagedDirectories: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseMediaTests-\(UUID().uuidString)", isDirectory: true)
        originals = root.appendingPathComponent("Originals", isDirectory: true)
        staging = root.appendingPathComponent("Staging", isDirectory: true)
        sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        if createManagedDirectories {
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }
    }

    func makeStore() throws -> ManagedAssetBlobStore {
        try ManagedAssetBlobStore(
            originalsDirectoryURL: originals,
            stagingDirectoryURL: staging
        )
    }

    func writeSource(named name: String, data: Data) throws -> URL {
        let url = sources.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    func remove() {
        guard root.lastPathComponent.hasPrefix("FramebaseMediaTests-") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

private func expectError(
    _ expected: ManagedAssetBlobStoreError,
    performing operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected), but the operation succeeded")
    } catch let error as ManagedAssetBlobStoreError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), but received \(error)")
    }
}
