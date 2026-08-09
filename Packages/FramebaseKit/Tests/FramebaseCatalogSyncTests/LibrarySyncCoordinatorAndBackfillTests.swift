import FramebaseAPIClient
import FramebaseCatalog
import FramebaseCatalogSync
import FramebaseDomain
import FramebaseSync
import Foundation
import Testing

private enum FakeSyncError: Error, Equatable {
    case pushFailed
}

private final class FakeSyncEngine: SyncEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _pushCallCount = 0
    private var _pullCallCount = 0
    var pushHandler: @Sendable () throws -> Int = { 0 }
    var pullHandler: @Sendable (Int) throws -> Int = { _ in 0 }

    var pushCallCount: Int { lock.withLock { _pushCallCount } }
    var pullCallCount: Int { lock.withLock { _pullCallCount } }

    func pushPending() async throws -> Int {
        lock.withLock { _pushCallCount += 1 }
        return try pushHandler()
    }

    func pullChanges(pageLimit: Int) async throws -> Int {
        lock.withLock { _pullCallCount += 1 }
        return try pullHandler(pageLimit)
    }
}

private final class TemporaryCatalog {
    let directoryURL: URL
    let databaseURL: URL
    let database: CatalogDatabase

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "LibrarySyncCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
        database = try CatalogDatabase(catalogURL: databaseURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class TemporarySyncState {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "LibrarySyncCoordinatorTests-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appending(path: "sync.sqlite", directoryHint: .notDirectory)
    }

    func openStore() throws -> SyncStateStore {
        try SyncStateStore(databaseURL: databaseURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@Suite("LibrarySyncCoordinator", .serialized)
struct LibrarySyncCoordinatorTests {
    @Test("syncNow() pushes then pulls and reports idle on success")
    func syncNowPushesThenPullsAndReportsIdle() async throws {
        let engine = FakeSyncEngine()
        let coordinator = LibrarySyncCoordinator(engine: engine)

        let status = await coordinator.syncNow()

        #expect(status == .idle)
        #expect(engine.pushCallCount == 1)
        #expect(engine.pullCallCount == 1)
    }

    @Test("A failing push reports .failed instead of throwing out of syncNow()")
    func failedPushReportsFailedStatus() async throws {
        let engine = FakeSyncEngine()
        engine.pushHandler = { throw FakeSyncError.pushFailed }
        let coordinator = LibrarySyncCoordinator(engine: engine)

        let status = await coordinator.syncNow()

        guard case .failed = status else {
            Issue.record("Expected .failed, got \(status)")
            return
        }
        #expect(engine.pushCallCount == 1)
        #expect(engine.pullCallCount == 0)
    }

    @Test("start() runs a sync immediately without waiting for the first interval, and stop() halts further runs")
    func startRunsImmediatelyAndStopHalts() async throws {
        let engine = FakeSyncEngine()
        // A long interval means a second automatic run would only happen if
        // stop() failed to cancel the loop within this test's timeout.
        let coordinator = LibrarySyncCoordinator(engine: engine, pullInterval: .seconds(3_600))

        await coordinator.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.pushCallCount == 1)

        await coordinator.stop()
        let countAtStop = engine.pushCallCount
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.pushCallCount == countAtStop)
    }
}

@Suite("CatalogFolderBackfill", .serialized)
struct CatalogFolderBackfillTests {
    @Test("Existing folders are enqueued parent-before-child, and the Inbox is skipped")
    func enqueuesExistingFoldersInParentBeforeChildOrder() async throws {
        let catalog = try TemporaryCatalog()
        let root = try await catalog.database.folders.createFolder(named: FolderName("Trips"), in: nil)
        let child = try await catalog.database.folders.createFolder(named: FolderName("2026"), in: root.id)
        let grandchild = try await catalog.database.folders.createFolder(named: FolderName("Japan"), in: child.id)

        let syncState = try TemporarySyncState()
        let outbox = try syncState.openStore()
        let recorder = CatalogOutboxRecorder(outbox: outbox, actorID: "backfill-test")

        try await CatalogFolderBackfill.enqueueExistingFolders(from: catalog.database.folders, into: recorder)

        let pending = try await outbox.pendingMutations()
        let targetIDs = pending.compactMap { $0.operations.first?.targetId }

        #expect(targetIDs.count == 3)
        #expect(!targetIDs.contains(catalog.database.inboxID.description))

        let rootIndex = try #require(targetIDs.firstIndex(of: root.id.description))
        let childIndex = try #require(targetIDs.firstIndex(of: child.id.description))
        let grandchildIndex = try #require(targetIDs.firstIndex(of: grandchild.id.description))
        #expect(rootIndex < childIndex)
        #expect(childIndex < grandchildIndex)

        for mutation in pending {
            #expect(mutation.operations.first?.type == .createFolder)
        }
    }
}
