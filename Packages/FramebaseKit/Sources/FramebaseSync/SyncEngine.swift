import FramebaseAPIClient
import Foundation

/// Drives the outbox and change feed against an `APIClientProtocol`. Owns no
/// storage of its own — `OutboxStore`, `SyncCursorStore`, and `ChangeApplier`
/// are all injected, so the engine is fully testable against fakes.
public protocol SyncEngine: Sendable {
    /// Drains pending outbox mutations in order, one `POST /v1/mutations`
    /// call per mutation. Stops and rethrows at the first failure rather than
    /// skipping ahead, since later mutations can depend on earlier ones.
    /// Returns the count successfully applied before any failure.
    @discardableResult
    func pushPending() async throws -> Int

    /// Pages through `GET /v1/changes` from the current cursor, applying and
    /// persisting the cursor after every individual event (not just every
    /// page), so a crash or transport error mid-pull leaves the cursor at
    /// exactly the last successfully applied event.
    @discardableResult
    func pullChanges(pageLimit: Int) async throws -> Int
}

public actor DefaultSyncEngine: SyncEngine {
    private let apiClient: any APIClientProtocol
    private let outbox: any OutboxStore
    private let cursorStore: any SyncCursorStore
    private let changeApplier: any ChangeApplier

    public init(
        apiClient: any APIClientProtocol,
        outbox: any OutboxStore,
        cursorStore: any SyncCursorStore,
        changeApplier: any ChangeApplier
    ) {
        self.apiClient = apiClient
        self.outbox = outbox
        self.cursorStore = cursorStore
        self.changeApplier = changeApplier
    }

    @discardableResult
    public func pushPending() async throws -> Int {
        var appliedCount = 0
        for mutation in try await outbox.pendingMutations() {
            do {
                _ = try await apiClient.submitMutations(
                    MutationsRequest(
                        clientMutationId: mutation.id,
                        actorId: mutation.actorId,
                        operations: mutation.operations
                    ),
                    idempotencyKey: mutation.id
                )
                try await outbox.markApplied(id: mutation.id)
                appliedCount += 1
            } catch {
                try? await outbox.recordFailure(id: mutation.id)
                throw error
            }
        }
        return appliedCount
    }

    @discardableResult
    public func pullChanges(pageLimit: Int) async throws -> Int {
        var appliedCount = 0
        while true {
            let after = try await cursorStore.currentRevision()
            let response = try await apiClient.fetchChanges(after: after, limit: pageLimit)
            guard !response.changes.isEmpty else { break }

            for event in response.changes {
                try await changeApplier.apply(event)
                try await cursorStore.advance(to: event.revision)
                appliedCount += 1
            }

            if !response.cursor.hasMore { break }
        }
        return appliedCount
    }
}
