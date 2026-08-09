import FramebaseSync
import Foundation

/// Decides *when* `SyncEngine.pushPending()`/`pullChanges()` run — the
/// piece `DefaultSyncEngine` deliberately doesn't own, since it's pure
/// push/pull mechanism with no opinion on scheduling. One coordinator per
/// activated library.
public actor LibrarySyncCoordinator {
    public enum Status: Equatable, Sendable {
        case idle
        case syncing
        case failed(String)
    }

    private let engine: any SyncEngine
    private let pullPageLimit: Int
    private let pullInterval: Duration
    private var status: Status = .idle
    private var loopTask: Task<Void, Never>?

    public init(engine: any SyncEngine, pullPageLimit: Int = 200, pullInterval: Duration = .seconds(120)) {
        self.engine = engine
        self.pullPageLimit = pullPageLimit
        self.pullInterval = pullInterval
    }

    public func currentStatus() -> Status {
        status
    }

    /// Idempotent: calling `start()` while already running does nothing.
    public func start() {
        guard loopTask == nil else { return }
        let interval = pullInterval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncNow()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Pushes pending outbox mutations, then pulls and applies new changes,
    /// once. A failure here sets `.failed` rather than throwing — one bad
    /// sync (offline, expired credential, server error) shouldn't kill the
    /// background loop or crash a caller who wants to trigger this
    /// on-demand.
    @discardableResult
    public func syncNow() async -> Status {
        status = .syncing
        do {
            try await engine.pushPending()
            try await engine.pullChanges(pageLimit: pullPageLimit)
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
        return status
    }
}
