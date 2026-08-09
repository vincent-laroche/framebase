import Foundation

/// A device's enrolled cloud session: the short-lived bearer JWT issued by
/// `POST /v1/auth/enroll` and the device id it was issued for.
public struct StoredDeviceCredential: Codable, Equatable, Sendable {
    public let deviceId: String
    public let token: String
    public let expiresAt: Date

    public init(deviceId: String, token: String, expiresAt: Date) {
        self.deviceId = deviceId
        self.token = token
        self.expiresAt = expiresAt
    }

    /// `Cloud/apps/api` issues 1-hour tokens with no refresh endpoint, so a
    /// small safety margin avoids sending a request that will be rejected by
    /// the time it reaches the server.
    public func isExpired(asOf date: Date = Date(), safetyMargin: TimeInterval = 30) -> Bool {
        date.addingTimeInterval(safetyMargin) >= expiresAt
    }
}

/// Persists the current device's cloud credential. The only concrete
/// conformance today is `KeychainDeviceCredentialStore`; the protocol exists
/// so tests can substitute an in-memory store.
public protocol DeviceCredentialStore: Sendable {
    func currentCredential() async throws -> StoredDeviceCredential?
    func store(_ credential: StoredDeviceCredential) async throws
    func clear() async throws
}
