import Foundation

/// Errors surfaced by `APIClientProtocol` conformances. Business-error codes
/// (`BLOB_NOT_FOUND`, `INVALID_SCOPE`, `MISSING_IDEMPOTENCY_KEY`, and so on) are
/// carried as raw strings from `Cloud/apps/api`'s `{error:{code,message}}`
/// envelope rather than modeled as a closed enum, since the server can add new
/// codes without a client release.
public enum APIClientError: Error, LocalizedError, Equatable, Sendable {
    case unauthorized(code: String, message: String)
    case forbidden(code: String, message: String)
    case badRequest(code: String, message: String)
    case notFound(code: String, message: String)
    case credentialsExpired
    case transport(message: String)
    case decoding(message: String)
    case serverError(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(_, let message): message
        case .forbidden(_, let message): message
        case .badRequest(_, let message): message
        case .notFound(_, let message): message
        case .credentialsExpired: "The stored device credential has expired. Re-enroll this device."
        case .transport(let message): message
        case .decoding(let message): "Could not decode the server response: \(message)"
        case .serverError(let status, let body): "Server error (\(status)): \(body)"
        }
    }
}
