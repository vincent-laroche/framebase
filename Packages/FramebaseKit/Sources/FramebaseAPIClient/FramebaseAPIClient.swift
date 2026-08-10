import CryptoKit
import Foundation
import FramebaseDomain

public struct FramebaseAPIConfiguration: Sendable {
    public let baseURL: URL
    public let requestTimeout: TimeInterval

    public init(baseURL: URL, requestTimeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }
}

public struct DeviceSession: Codable, Hashable, Sendable {
    public let deviceID: String
    public let token: String
    public let expiresAt: Date

    public init(deviceID: String, token: String, expiresAt: Date) {
        self.deviceID = deviceID
        self.token = token
        self.expiresAt = expiresAt
    }

    public var isUsable: Bool { expiresAt > Date().addingTimeInterval(30) }
}

public protocol DeviceSessionStore: Sendable {
    func load() async throws -> DeviceSession?
    func save(_ session: DeviceSession) async throws
    func clear() async throws
}

public struct InMemoryDeviceSessionStore: DeviceSessionStore {
    private let storage: Storage

    public init(session: DeviceSession? = nil) {
        storage = Storage(session: session)
    }

    public func load() async throws -> DeviceSession? { await storage.session }
    public func save(_ session: DeviceSession) async throws { await storage.set(session) }
    public func clear() async throws { await storage.set(nil) }

    private actor Storage {
        var session: DeviceSession?
        init(session: DeviceSession?) { self.session = session }
        func set(_ session: DeviceSession?) { self.session = session }
    }
}

public struct FramebaseAPIError: Error, LocalizedError, Equatable, Sendable {
    public let statusCode: Int
    public let code: String
    public let message: String
    public let requestID: String?

    public init(statusCode: Int, code: String, message: String, requestID: String? = nil) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
        self.requestID = requestID
    }

    public var errorDescription: String? { message }
    public var isConflict: Bool { statusCode == 409 || code == "STALE_REVISION" }
    public var isUnauthorized: Bool { statusCode == 401 }
}

public struct DeviceEnrollmentChallenge: Codable, Hashable, Sendable {
    public let challengeID: String
    public let challenge: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey { case challengeID = "challengeId"; case challenge; case expiresAt }
}

public struct DeviceEnrollmentRequest: Codable, Hashable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let publicKey: String
    public let scopes: [String]

    public init(deviceID: String, deviceName: String, publicKey: String, scopes: [String]) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.scopes = scopes
    }
}

public struct RemoteBlobIntent: Codable, Hashable, Sendable {
    public let sha256: String
    public let byteSize: Int64
    public let mediaType: String
    public let originalExtension: String

    public init(sha256: String, byteSize: Int64, mediaType: String, originalExtension: String) {
        self.sha256 = sha256
        self.byteSize = byteSize
        self.mediaType = mediaType
        self.originalExtension = originalExtension
    }
}

public struct DirectTransferCapability: Codable, Hashable, Sendable {
    public let url: URL
    public let method: String
    public let expiresAt: Date
    public let headers: [String: String]?

    enum CodingKeys: String, CodingKey {
        case url, method, expiresAt
        case headers = "requiredHeaders"
    }
}

public struct UploadInitiation: Codable, Hashable, Sendable {
    public let status: String
    public let blobID: String
    public let upload: DirectTransferCapability?

    enum CodingKeys: String, CodingKey { case status; case blobID = "blobId"; case upload }

    public init(status: String, blobID: String, upload: DirectTransferCapability? = nil) {
        self.status = status
        self.blobID = blobID
        self.upload = upload
    }
}

public struct MultipartUploadedPart: Codable, Hashable, Sendable {
    public let partNumber: Int
    public let etag: String
    public let byteSize: Int64?

}

public struct MultipartUploadInitiation: Codable, Hashable, Sendable {
    public let status: String
    public let blobID: String
    public let uploadID: String?
    public let partByteSize: Int?
    public let partCount: Int?
    public let uploadedParts: [MultipartUploadedPart]

    enum CodingKeys: String, CodingKey {
        case status, blobID = "blobId", uploadID = "uploadId", partByteSize, partCount, uploadedParts
    }
}

public struct MultipartUploadCompletion: Codable, Hashable, Sendable {
    public let status: String
    public let blobID: String
    public let uploadID: String

    enum CodingKeys: String, CodingKey { case status; case blobID = "blobId"; case uploadID = "uploadId" }
}

public struct RemoteChangeEvent: Decodable, Hashable, Sendable {
    public let revision: Int64
    public let entityType: String
    public let entityID: String
    public let operation: String
    public let payload: Data
    public let actorID: String
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case revision, entityType, entityID = "entityId", operation, payload, actorID = "actorId", createdAt
    }

    public init(
        revision: Int64,
        entityType: String,
        entityID: String,
        operation: String,
        payload: Data,
        actorID: String,
        createdAt: Date = .now
    ) {
        self.revision = revision
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.payload = payload
        self.actorID = actorID
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(Int64.self, forKey: .revision)
        entityType = try values.decode(String.self, forKey: .entityType)
        entityID = try values.decode(String.self, forKey: .entityID)
        operation = try values.decode(String.self, forKey: .operation)
        payload = try JSONSerialization.data(withJSONObject: values.decode(JSONValue.self, forKey: .payload).objectValue)
        actorID = try values.decode(String.self, forKey: .actorID)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

public struct ChangeFeedPage: Decodable, Hashable, Sendable {
    public let events: [RemoteChangeEvent]
    public let nextCursor: Int64?

    private enum CodingKeys: String, CodingKey { case changes, cursor }
    private struct Cursor: Decodable { let nextCursor: Int64 }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        events = try values.decode([RemoteChangeEvent].self, forKey: .changes)
        nextCursor = try values.decode(Cursor.self, forKey: .cursor).nextCursor
    }

    public init(events: [RemoteChangeEvent] = [], nextCursor: Int64? = nil) {
        self.events = events
        self.nextCursor = nextCursor
    }
}

public struct RemoteCatalogEntity: Decodable, Hashable, Sendable {
    public let entityType: String
    public let entityID: String
    public let revision: Int64
    public let payload: Data

    private enum CodingKeys: String, CodingKey { case entityType, entityID = "entityId", revision, payload }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entityType = try values.decode(String.self, forKey: .entityType)
        entityID = try values.decode(String.self, forKey: .entityID)
        revision = try values.decode(Int64.self, forKey: .revision)
        payload = try JSONSerialization.data(withJSONObject: values.decode(JSONValue.self, forKey: .payload).objectValue)
    }

    public init(entityType: String, entityID: String, revision: Int64, payload: Data) {
        self.entityType = entityType
        self.entityID = entityID
        self.revision = revision
        self.payload = payload
    }
}

public struct CatalogBootstrapPage: Decodable, Hashable, Sendable {
    public let watermarkRevision: Int64
    public let entities: [RemoteCatalogEntity]
    public let nextCursor: String?

    public init(watermarkRevision: Int64, entities: [RemoteCatalogEntity], nextCursor: String? = nil) {
        self.watermarkRevision = watermarkRevision
        self.entities = entities
        self.nextCursor = nextCursor
    }
}

public struct TemporaryDownload: Sendable {
    public let fileURL: URL
    public let sha256: String
    public let byteSize: Int64
}

public enum CloudDerivativeVariant: String, CaseIterable, Sendable {
    case grid256 = "grid-256"
    case grid512 = "grid-512"
    case preview1600 = "preview-1600"
}

/// The narrow transport boundary used by the sync actor. It keeps the actor
/// testable with a deterministic private fixture while the production app
/// continues to use the authenticated HTTP client below.
public protocol FramebaseSyncAPI: Sendable {
    func initiateUpload(_ intent: RemoteBlobIntent) async throws -> UploadInitiation
    func upload(_ data: Data, using capability: DirectTransferCapability) async throws
    func completeUpload(sha256: String, byteSize: Int64) async throws
    func initiateMultipartUpload(_ intent: RemoteBlobIntent) async throws -> MultipartUploadInitiation
    func uploadMultipartPart(_ data: Data, uploadID: String, partNumber: Int) async throws -> MultipartUploadedPart
    func completeMultipartUpload(uploadID: String) async throws -> MultipartUploadCompletion
    func verificationDownloadCapability(blobID: String) async throws -> DirectTransferCapability
    func confirmMultipartUpload(uploadID: String, sha256: String, byteSize: Int64) async throws
    func downloadCapability(blobID: String) async throws -> DirectTransferCapability
    func downloadSHA256(_ capability: DirectTransferCapability) async throws -> (sha256: String, byteSize: Int64)
    func downloadToTemporaryFile(_ capability: DirectTransferCapability) async throws -> TemporaryDownload
    func applyMutation(payload: Data, idempotencyKey: String) async throws -> Data
    func changes(after cursor: Int64) async throws -> ChangeFeedPage
    func bootstrapCatalog(cursor: String?) async throws -> CatalogBootstrapPage
}

public actor FramebaseAPIClient: FramebaseSyncAPI {
    private let configuration: FramebaseAPIConfiguration
    private let sessionStore: any DeviceSessionStore
    private let urlSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: FramebaseAPIConfiguration,
        sessionStore: any DeviceSessionStore,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.sessionStore = sessionStore
        self.urlSession = urlSession
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func enroll(
        request: DeviceEnrollmentRequest,
        pairingCredential: String
    ) async throws -> DeviceSession {
        var urlRequest = try makeRequest(path: "v1/auth/enroll", method: "POST")
        urlRequest.setValue(pairingCredential, forHTTPHeaderField: "X-Enrollment-Secret")
        urlRequest.httpBody = try encoder.encode(request)
        let response: EnrollmentResponse = try await perform(urlRequest, decode: EnrollmentResponse.self)
        let session = DeviceSession(deviceID: response.deviceID, token: response.token, expiresAt: response.expiresAt)
        try await sessionStore.save(session)
        return session
    }

    /// Completes the Phase 3 proof-of-possession enrollment flow. The pairing
    /// credential authorizes this one enrollment but is never stored here.
    public func enroll(
        request: DeviceEnrollmentRequest,
        pairingCredential: String,
        signer: any DeviceKeySigning
    ) async throws -> DeviceSession {
        var challengeRequest = try makeRequest(path: "v1/auth/enroll/challenge", method: "POST")
        challengeRequest.setValue(pairingCredential, forHTTPHeaderField: "X-Pairing-Credential")
        challengeRequest.httpBody = try encoder.encode(request)
        let challenge = try await perform(challengeRequest, decode: DeviceEnrollmentChallenge.self)
        let canonicalPayload = Data("\(challenge.challengeID).\(request.deviceID).\(challenge.challenge)".utf8)
        let signature = try signer.sign(canonicalPayload)
        var completeRequest = try makeRequest(path: "v1/auth/enroll/complete", method: "POST")
        completeRequest.httpBody = try encoder.encode(EnrollmentCompletion(
            challengeID: challenge.challengeID,
            signature: signature.base64URLEncodedString()
        ))
        let response: EnrollmentResponse = try await perform(completeRequest, decode: EnrollmentResponse.self)
        let session = DeviceSession(deviceID: response.deviceID, token: response.token, expiresAt: response.expiresAt)
        try await sessionStore.save(session)
        return session
    }

    public func initiateUpload(_ intent: RemoteBlobIntent) async throws -> UploadInitiation {
        var urlRequest = try await request(path: "v1/blobs/upload-initiate", method: "POST", authenticated: true)
        urlRequest.httpBody = try encoder.encode(intent)
        return try await perform(urlRequest, decode: UploadInitiation.self)
    }

    public func upload(_ data: Data, using capability: DirectTransferCapability) async throws {
        guard capability.expiresAt > Date() else {
            throw FramebaseAPIError(statusCode: 410, code: "CAPABILITY_EXPIRED", message: "Upload capability expired")
        }
        var request = URLRequest(url: capability.url, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = capability.method
        for (key, value) in capability.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = data
        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FramebaseAPIError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "DIRECT_UPLOAD_FAILED", message: "Direct upload failed")
        }
    }

    public func completeUpload(sha256: String, byteSize: Int64) async throws {
        var request = try await request(path: "v1/blobs/upload-complete", method: "POST", authenticated: true)
        request.httpBody = try encoder.encode(UploadCompletionRequest(sha256: sha256, byteSize: byteSize))
        _ = try await perform(request, decode: UploadCompletionResponse.self)
    }

    public func initiateMultipartUpload(_ intent: RemoteBlobIntent) async throws -> MultipartUploadInitiation {
        var request = try await request(path: "v1/blobs/multipart/initiate", method: "POST", authenticated: true)
        request.httpBody = try encoder.encode(intent)
        return try await perform(request, decode: MultipartUploadInitiation.self)
    }

    public func uploadMultipartPart(_ data: Data, uploadID: String, partNumber: Int) async throws -> MultipartUploadedPart {
        var request = try await request(path: "v1/blobs/multipart/\(uploadID)/parts/\(partNumber)", method: "PUT", authenticated: true)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await perform(request, decode: MultipartUploadedPart.self)
    }

    public func completeMultipartUpload(uploadID: String) async throws -> MultipartUploadCompletion {
        let request = try await request(path: "v1/blobs/multipart/\(uploadID)/complete", method: "POST", authenticated: true)
        return try await perform(request, decode: MultipartUploadCompletion.self)
    }

    public func verificationDownloadCapability(blobID: String) async throws -> DirectTransferCapability {
        let request = try await request(path: "v1/blobs/\(blobID)/verification-download", method: "GET", authenticated: true)
        return try await perform(request, decode: DownloadResponse.self).download
    }

    public func confirmMultipartUpload(uploadID: String, sha256: String, byteSize: Int64) async throws {
        var request = try await request(path: "v1/blobs/multipart/\(uploadID)/confirm", method: "POST", authenticated: true)
        request.httpBody = try encoder.encode(UploadCompletionRequest(sha256: sha256, byteSize: byteSize))
        _ = try await perform(request, decode: UploadCompletionResponse.self)
    }

    public func downloadCapability(blobID: String) async throws -> DirectTransferCapability {
        let request = try await request(path: "v1/blobs/\(blobID)/download", method: "GET", authenticated: true)
        return try await perform(request, decode: DownloadResponse.self).download
    }

    public func download(_ capability: DirectTransferCapability) async throws -> Data {
        guard capability.expiresAt > Date() else {
            throw FramebaseAPIError(statusCode: 410, code: "CAPABILITY_EXPIRED", message: "Download capability expired")
        }
        var request = URLRequest(url: capability.url, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = capability.method
        for (key, value) in capability.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FramebaseAPIError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "DIRECT_DOWNLOAD_FAILED", message: "Direct download failed")
        }
        return data
    }

    /// Materializes a private verification download to a system temporary file,
    /// hashes it in bounded chunks, and removes that temporary copy afterwards.
    public func downloadSHA256(_ capability: DirectTransferCapability) async throws -> (sha256: String, byteSize: Int64) {
        let download = try await downloadToTemporaryFile(capability)
        defer { try? FileManager.default.removeItem(at: download.fileURL) }
        return (download.sha256, download.byteSize)
    }

    /// Leaves an audited, system-temporary download for the caller to pass
    /// through managed storage. The caller must remove it after materializing.
    public func downloadToTemporaryFile(_ capability: DirectTransferCapability) async throws -> TemporaryDownload {
        guard capability.expiresAt > Date() else {
            throw FramebaseAPIError(statusCode: 410, code: "CAPABILITY_EXPIRED", message: "Download capability expired")
        }
        var request = URLRequest(url: capability.url, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = capability.method
        for (key, value) in capability.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        let (temporaryURL, response) = try await urlSession.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FramebaseAPIError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "DIRECT_DOWNLOAD_FAILED", message: "Direct download failed")
        }
        let hash = try Self.sha256(of: temporaryURL)
        return TemporaryDownload(fileURL: temporaryURL, sha256: hash.sha256, byteSize: hash.byteSize)
    }

    public func applyMutation(payload: Data, idempotencyKey: String) async throws -> Data {
        var request = try await request(path: "v1/mutations", method: "POST", authenticated: true)
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = payload
        return try await performRaw(request)
    }

    public func changes(after cursor: Int64) async throws -> ChangeFeedPage {
        let request = try await request(path: "v1/changes?after=\(max(0, cursor))", method: "GET", authenticated: true)
        return try await perform(request, decode: ChangeFeedPage.self)
    }

    public func bootstrapCatalog(cursor: String? = nil) async throws -> CatalogBootstrapPage {
        let suffix = cursor.map { "?cursor=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? ""
        let request = try await request(path: "v1/catalog/bootstrap\(suffix)", method: "GET", authenticated: true)
        return try await perform(request, decode: CatalogBootstrapPage.self)
    }

    public func derivative(
        assetID: String,
        variant: CloudDerivativeVariant
    ) async throws -> Data {
        var request = try await request(
            path: "v1/assets/\(assetID)/variants/\(variant.rawValue)", method: "GET", authenticated: true
        )
        request.setValue("image/webp", forHTTPHeaderField: "Accept")
        return try await performRaw(request)
    }

    public func clearSession() async throws { try await sessionStore.clear() }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        let base = configuration.baseURL.absoluteString.hasSuffix("/")
            ? configuration.baseURL.absoluteString
            : configuration.baseURL.absoluteString + "/"
        guard let url = URL(string: base + path) else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_URL", message: "Invalid API URL")
        }
        var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func request(path: String, method: String, authenticated: Bool) async throws -> URLRequest {
        var request = try makeRequest(path: path, method: method)
        guard authenticated else { return request }
        guard let session = try await sessionStore.load(), session.isUsable else {
            throw FramebaseAPIError(statusCode: 401, code: "SESSION_UNAVAILABLE", message: "Device session is unavailable or expired")
        }
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest, decode: Response.Type) async throws -> Response {
        let data = try await performRaw(request)
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw FramebaseAPIError(statusCode: 0, code: "INVALID_RESPONSE", message: "API response could not be decoded") }
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_RESPONSE", message: "API returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? decoder.decode(APIErrorEnvelope.self, from: data) {
                throw FramebaseAPIError(statusCode: http.statusCode, code: error.error.code, message: error.error.message, requestID: error.error.requestID)
            }
            throw FramebaseAPIError(statusCode: http.statusCode, code: "HTTP_\(http.statusCode)", message: "API request failed")
        }
        return data
    }

    private static func sha256(of url: URL) throws -> (sha256: String, byteSize: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteSize: Int64 = 0
        while true {
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            byteSize += Int64(data.count)
            hasher.update(data: data)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteSize)
    }
}

private struct EnrollmentResponse: Codable {
    let deviceID: String
    let token: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case deviceID = "deviceId"; case token; case expiresAt }
}

private struct EnrollmentCompletion: Codable {
    let challengeID: String
    let signature: String
    enum CodingKeys: String, CodingKey { case challengeID = "challengeId"; case signature }
}
private struct UploadCompletionRequest: Codable {
    let sha256: String
    let byteSize: Int64
}
private struct UploadCompletionResponse: Codable { let status: String }
private struct DownloadResponse: Codable { let download: DirectTransferCapability }
private struct APIErrorEnvelope: Codable { let error: APIErrorBody }
private struct APIErrorBody: Codable { let code: String; let message: String; let requestID: String? }

private enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    var objectValue: Any {
        switch self {
        case let .object(value): value.mapValues(\.objectValue)
        case let .array(value): value.map(\.objectValue)
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case .null: NSNull()
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws { fatalError("JSONValue encoding is not used") }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
