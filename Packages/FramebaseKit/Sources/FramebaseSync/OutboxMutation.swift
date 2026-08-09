import FramebaseAPIClient
import Foundation

/// A batch of catalog operations queued for push to the cloud. `id` is used
/// both as the outbox row's primary key and as the `Idempotency-Key` sent to
/// `POST /v1/mutations`, so a retry after a crash or dropped connection
/// replays the server's cached response instead of double-applying.
public struct OutboxMutation: Codable, Equatable, Sendable {
    public let id: String
    public let actorId: String
    public let operations: [MutationOperation]
    public let createdAt: Date
    public let attemptCount: Int

    public init(
        id: String = UUID().uuidString,
        actorId: String,
        operations: [MutationOperation],
        createdAt: Date = Date(),
        attemptCount: Int = 0
    ) {
        self.id = id
        self.actorId = actorId
        self.operations = operations
        self.createdAt = createdAt
        self.attemptCount = attemptCount
    }
}
