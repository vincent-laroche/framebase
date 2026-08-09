import Foundation

/// Persists the last change-feed `revision` this device has applied.
/// Monotonic: `advance(to:)` never moves the cursor backward, so a stale or
/// out-of-order call cannot corrupt sync progress.
public protocol SyncCursorStore: Sendable {
    func currentRevision() async throws -> Int
    func advance(to revision: Int) async throws
}
