import FramebaseDomain

/// Emitted only after a manifest state has been durably recorded. This keeps
/// migration observation aligned with restart-safe recovery points.
public struct MigrationProgress: Equatable, Sendable {
    public let assetID: AssetID
    public let state: MigrationManifestState
    public let retryCount: Int

    public init(assetID: AssetID, state: MigrationManifestState, retryCount: Int) {
        self.assetID = assetID
        self.state = state
        self.retryCount = retryCount
    }
}
