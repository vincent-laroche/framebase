import FramebaseAPIClient

/// Applies one pulled `ChangeEvent` to local state. No concrete conformance
/// exists yet — wiring this to the real `CatalogDatabase` is real-catalog
/// sync integration, deliberately out of scope until Phase 2's "fixture
/// assets only, no personal photos" boundary is explicitly lifted.
public protocol ChangeApplier: Sendable {
    func apply(_ event: ChangeEvent) async throws
}
