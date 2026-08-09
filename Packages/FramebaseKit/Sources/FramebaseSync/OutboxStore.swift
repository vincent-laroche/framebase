import Foundation

/// Persistence for pending outbound mutations. The only concrete conformance
/// today is `SyncStateStore`; the protocol exists so `SyncEngine` can be
/// tested against an in-memory fake.
public protocol OutboxStore: Sendable {
    func enqueue(_ mutation: OutboxMutation) async throws

    /// Pending mutations in submission order (oldest first). Mutation order
    /// matters — later operations can depend on earlier ones (for example,
    /// moving assets into a folder created by a prior mutation) — so callers
    /// must drain this in order and stop at the first failure.
    func pendingMutations() async throws -> [OutboxMutation]

    func markApplied(id: String) async throws
    func recordFailure(id: String) async throws
}
