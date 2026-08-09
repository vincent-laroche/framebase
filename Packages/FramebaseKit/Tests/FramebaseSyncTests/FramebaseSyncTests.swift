import FramebaseAPIClient
import Foundation
import Testing
@testable import FramebaseSync

private enum FakeTransportError: Error, Equatable {
    case simulatedFailure
}

private enum FakeApplierError: Error, Equatable {
    case simulatedFailure(revision: Int)
}

/// A fake `APIClientProtocol` exercising only the two methods `SyncEngine`
/// calls. The other endpoints intentionally `fatalError` if reached, since a
/// call to them here would mean `DefaultSyncEngine` grew a dependency this
/// test suite doesn't know about.
private final class FakeAPIClient: APIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _submittedRequests: [(request: MutationsRequest, idempotencyKey: String)] = []

    var submitHandler: @Sendable (MutationsRequest, String) throws -> MutationsResponse = { request, key in
        MutationsResponse(
            status: "applied",
            clientMutationId: key,
            appliedCount: request.operations.count,
            results: request.operations.map { MutationResult(targetId: $0.targetId, revision: 1) }
        )
    }

    var changesHandler: @Sendable (Int, Int) -> ChangesResponse = { after, _ in
        ChangesResponse(changes: [], cursor: ChangesCursor(after: after, lastRevision: after, hasMore: false))
    }

    var submittedRequests: [(request: MutationsRequest, idempotencyKey: String)] {
        lock.withLock { _submittedRequests }
    }

    func health() async throws -> HealthResponse { fatalError("not used in these tests") }

    func enroll(enrollmentSecret: String, request: EnrollRequest) async throws -> EnrollResponse {
        fatalError("not used in these tests")
    }

    func initiateBlobUpload(_ request: BlobUploadInitiateRequest) async throws -> BlobUploadInitiateResponse {
        fatalError("not used in these tests")
    }

    func uploadBlobBytes(
        _ data: Data,
        contentType: String,
        toRelativePath relativePath: String
    ) async throws -> BlobUploadDirectResponse {
        fatalError("not used in these tests")
    }

    func uploadBlobFile(
        at fileURL: URL,
        contentType: String,
        toRelativePath relativePath: String
    ) async throws -> BlobUploadDirectResponse {
        fatalError("not used in these tests")
    }

    func completeBlobUpload(_ request: BlobUploadCompleteRequest) async throws -> BlobUploadCompleteResponse {
        fatalError("not used in these tests")
    }

    func downloadBlob(id: String) async throws -> BlobDownload { fatalError("not used in these tests") }

    func registerAsset(_ request: AssetRegistrationRequest, idempotencyKey: String) async throws -> AssetRegistrationResponse {
        fatalError("not used in these tests")
    }

    func fetchChanges(after: Int, limit: Int) async throws -> ChangesResponse {
        changesHandler(after, limit)
    }

    func submitMutations(_ request: MutationsRequest, idempotencyKey: String) async throws -> MutationsResponse {
        lock.withLock { _submittedRequests.append((request, idempotencyKey)) }
        return try submitHandler(request, idempotencyKey)
    }
}

private final class RecordingChangeApplier: ChangeApplier, @unchecked Sendable {
    private let lock = NSLock()
    private var _appliedRevisions: [Int] = []
    var failOnRevision: Int?

    var appliedRevisions: [Int] {
        lock.withLock { _appliedRevisions }
    }

    func apply(_ event: ChangeEvent) async throws {
        if event.revision == failOnRevision {
            throw FakeApplierError.simulatedFailure(revision: event.revision)
        }
        lock.withLock { _appliedRevisions.append(event.revision) }
    }
}

/// Mirrors `FramebaseCatalogTests`' `TemporaryCatalog` pattern: a real
/// on-disk GRDB database per test, cleaned up on deinit, so persistence
/// across separate `SyncStateStore` instances (simulating an app restart)
/// can actually be exercised.
private final class TemporarySyncState {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "FramebaseSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

@Suite("FramebaseSync", .serialized)
struct FramebaseSyncTests {
    @Test("pushPending() drains the outbox in submission order")
    func outboxDrainsInOrder() async throws {
        let temporary = try TemporarySyncState()
        let store = try temporary.openStore()
        let apiClient = FakeAPIClient()
        let engine = DefaultSyncEngine(
            apiClient: apiClient,
            outbox: store,
            cursorStore: store,
            changeApplier: RecordingChangeApplier()
        )

        try await store.enqueue(OutboxMutation(
            actorId: "device-1",
            operations: [MutationOperation(type: .createFolder, targetId: "folder-a", payload: .null)]
        ))
        try await store.enqueue(OutboxMutation(
            actorId: "device-1",
            operations: [MutationOperation(type: .createFolder, targetId: "folder-b", payload: .null)]
        ))
        try await store.enqueue(OutboxMutation(
            actorId: "device-1",
            operations: [MutationOperation(type: .createFolder, targetId: "folder-c", payload: .null)]
        ))

        let appliedCount = try await engine.pushPending()

        #expect(appliedCount == 3)
        #expect(apiClient.submittedRequests.compactMap { $0.request.operations.first?.targetId } == [
            "folder-a", "folder-b", "folder-c"
        ])
        #expect(try await store.pendingMutations().isEmpty)
    }

    @Test("A retried mutation reuses the same idempotency key")
    func idempotencyKeyIsStableAcrossRetries() async throws {
        let temporary = try TemporarySyncState()
        let store = try temporary.openStore()
        let apiClient = FakeAPIClient()
        let engine = DefaultSyncEngine(
            apiClient: apiClient,
            outbox: store,
            cursorStore: store,
            changeApplier: RecordingChangeApplier()
        )

        let mutation = OutboxMutation(
            actorId: "device-1",
            operations: [MutationOperation(type: .createFolder, targetId: "folder-a", payload: .null)]
        )
        try await store.enqueue(mutation)

        apiClient.submitHandler = { _, _ in throw FakeTransportError.simulatedFailure }
        await #expect(throws: FakeTransportError.simulatedFailure) {
            try await engine.pushPending()
        }
        let pendingAfterFailure = try await store.pendingMutations()
        #expect(pendingAfterFailure.count == 1)
        #expect(pendingAfterFailure[0].attemptCount == 1)

        apiClient.submitHandler = { request, key in
            MutationsResponse(status: "applied", clientMutationId: key, appliedCount: 1, results: [
                MutationResult(targetId: request.operations[0].targetId, revision: 1)
            ])
        }
        let appliedCount = try await engine.pushPending()

        #expect(appliedCount == 1)
        #expect(try await store.pendingMutations().isEmpty)
        let usedKeys = Set(apiClient.submittedRequests.map(\.idempotencyKey))
        #expect(usedKeys == [mutation.id])
    }

    @Test("The change-feed cursor advances monotonically and survives an engine restart")
    func cursorPersistsAcrossRestart() async throws {
        let temporary = try TemporarySyncState()

        let firstStore = try temporary.openStore()
        let firstClient = FakeAPIClient()
        firstClient.changesHandler = { after, _ in
            #expect(after == 0)
            return ChangesResponse(
                changes: [
                    ChangeEvent(
                        revision: 3, entityType: "folder", entityId: "folder-a", operation: "create",
                        payload: .null, actorId: "device-1", clientMutationId: nil, createdAt: "2026-08-09T12:00:00.000Z"
                    ),
                    ChangeEvent(
                        revision: 4, entityType: "folder", entityId: "folder-b", operation: "create",
                        payload: .null, actorId: "device-1", clientMutationId: nil, createdAt: "2026-08-09T12:00:01.000Z"
                    )
                ],
                cursor: ChangesCursor(after: after, lastRevision: 4, hasMore: false)
            )
        }
        let firstEngine = DefaultSyncEngine(
            apiClient: firstClient,
            outbox: firstStore,
            cursorStore: firstStore,
            changeApplier: RecordingChangeApplier()
        )
        let firstAppliedCount = try await firstEngine.pullChanges(pageLimit: 100)
        #expect(firstAppliedCount == 2)
        #expect(try await firstStore.currentRevision() == 4)

        // Simulate an app restart: open a fresh SyncStateStore against the
        // same database file rather than reusing the in-memory instance.
        let restartedStore = try temporary.openStore()
        #expect(try await restartedStore.currentRevision() == 4)

        let secondClient = FakeAPIClient()
        secondClient.changesHandler = { after, _ in
            #expect(after == 4)
            return ChangesResponse(
                changes: [
                    ChangeEvent(
                        revision: 5, entityType: "folder", entityId: "folder-c", operation: "create",
                        payload: .null, actorId: "device-1", clientMutationId: nil, createdAt: "2026-08-09T12:00:02.000Z"
                    )
                ],
                cursor: ChangesCursor(after: after, lastRevision: 5, hasMore: false)
            )
        }
        let secondEngine = DefaultSyncEngine(
            apiClient: secondClient,
            outbox: restartedStore,
            cursorStore: restartedStore,
            changeApplier: RecordingChangeApplier()
        )
        let secondAppliedCount = try await secondEngine.pullChanges(pageLimit: 100)
        #expect(secondAppliedCount == 1)
        #expect(try await restartedStore.currentRevision() == 5)
    }

    @Test("A failure mid-pull leaves the cursor at the last successfully applied revision")
    func partialPullFailureLeavesCursorAtLastSuccess() async throws {
        let temporary = try TemporarySyncState()
        let store = try temporary.openStore()
        let apiClient = FakeAPIClient()
        apiClient.changesHandler = { after, _ in
            ChangesResponse(
                changes: [
                    ChangeEvent(
                        revision: 10, entityType: "folder", entityId: "folder-a", operation: "create",
                        payload: .null, actorId: "device-1", clientMutationId: nil, createdAt: "2026-08-09T12:00:00.000Z"
                    ),
                    ChangeEvent(
                        revision: 11, entityType: "folder", entityId: "folder-b", operation: "create",
                        payload: .null, actorId: "device-1", clientMutationId: nil, createdAt: "2026-08-09T12:00:01.000Z"
                    ),
                    ChangeEvent(
                        revision: 12, entityType: "folder", entityId: "folder-c", operation: "create",
                        payload: .null, actorId: "device-1", clientMutationId: nil, createdAt: "2026-08-09T12:00:02.000Z"
                    )
                ],
                cursor: ChangesCursor(after: after, lastRevision: 12, hasMore: false)
            )
        }
        let applier = RecordingChangeApplier()
        applier.failOnRevision = 11
        let engine = DefaultSyncEngine(apiClient: apiClient, outbox: store, cursorStore: store, changeApplier: applier)

        await #expect(throws: FakeApplierError.simulatedFailure(revision: 11)) {
            try await engine.pullChanges(pageLimit: 100)
        }

        #expect(applier.appliedRevisions == [10])
        #expect(try await store.currentRevision() == 10)
    }
}
