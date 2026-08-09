import Foundation

/// URLSession-based conformance to `APIClientProtocol`, talking to a
/// `framebase-api-dev`-shaped `/v1` Worker over HTTPS.
public final class FramebaseAPIClient: APIClientProtocol, Sendable {
    private let baseURL: URL
    private let credentialStore: any DeviceCredentialStore
    private let urlSession: URLSession

    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    public init(
        baseURL: URL,
        credentialStore: any DeviceCredentialStore,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.credentialStore = credentialStore
        self.urlSession = urlSession
    }

    public func health() async throws -> HealthResponse {
        let request = try await makeRequest(method: "GET", path: "/v1/health", authenticated: false)
        return try await performJSON(request)
    }

    public func enroll(enrollmentSecret: String, request enrollRequest: EnrollRequest) async throws -> EnrollResponse {
        var request = try await makeRequest(method: "POST", path: "/v1/auth/enroll", authenticated: false)
        request.setValue(enrollmentSecret, forHTTPHeaderField: "X-Enrollment-Secret")
        request.httpBody = try Self.jsonEncoder.encode(enrollRequest)
        return try await performJSON(request)
    }

    public func fetchChanges(after: Int, limit: Int) async throws -> ChangesResponse {
        let request = try await makeRequest(
            method: "GET",
            path: "/v1/changes",
            authenticated: true,
            queryItems: [
                URLQueryItem(name: "after", value: String(after)),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
        return try await performJSON(request)
    }

    public func initiateBlobUpload(_ body: BlobUploadInitiateRequest) async throws -> BlobUploadInitiateResponse {
        var request = try await makeRequest(method: "POST", path: "/v1/blobs/upload-initiate", authenticated: true)
        request.httpBody = try Self.jsonEncoder.encode(body)
        return try await performJSON(request)
    }

    public func uploadBlobBytes(
        _ data: Data,
        contentType: String,
        toRelativePath relativePath: String
    ) async throws -> BlobUploadDirectResponse {
        guard let resolvedURL = URL(string: relativePath, relativeTo: baseURL) else {
            throw APIClientError.badRequest(
                code: "INVALID_UPLOAD_PATH",
                message: "Malformed upload path: \(relativePath)"
            )
        }
        var request = URLRequest(url: resolvedURL.absoluteURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        try await attachAuthorization(to: &request)
        request.httpBody = data
        return try await performJSON(request)
    }

    public func uploadBlobFile(
        at fileURL: URL,
        contentType: String,
        toRelativePath relativePath: String
    ) async throws -> BlobUploadDirectResponse {
        guard fileURL.isFileURL, let resolvedURL = URL(string: relativePath, relativeTo: baseURL) else {
            throw APIClientError.badRequest(
                code: "INVALID_UPLOAD_PATH",
                message: "Malformed upload path: \(relativePath)"
            )
        }
        var request = URLRequest(url: resolvedURL.absoluteURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        try await attachAuthorization(to: &request)
        return try await performJSON(request, uploadingFileAt: fileURL)
    }

    public func completeBlobUpload(_ body: BlobUploadCompleteRequest) async throws -> BlobUploadCompleteResponse {
        var request = try await makeRequest(method: "POST", path: "/v1/blobs/upload-complete", authenticated: true)
        request.httpBody = try Self.jsonEncoder.encode(body)
        return try await performJSON(request)
    }

    public func downloadBlob(id: String) async throws -> BlobDownload {
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw APIClientError.badRequest(code: "INVALID_BLOB_ID", message: "Malformed blob id: \(id)")
        }
        let request = try await makeRequest(
            method: "GET",
            path: "/v1/blobs/\(encodedID)/download",
            authenticated: true
        )

        let (data, response) = try await performRaw(request)
        return BlobDownload(
            data: data,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            etag: response.value(forHTTPHeaderField: "etag")
        )
    }

    public func registerAsset(_ body: AssetRegistrationRequest, idempotencyKey: String) async throws -> AssetRegistrationResponse {
        var request = try await makeRequest(method: "POST", path: "/v1/assets/register", authenticated: true)
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try Self.jsonEncoder.encode(body)
        return try await performJSON(request)
    }

    public func submitMutations(_ body: MutationsRequest, idempotencyKey: String) async throws -> MutationsResponse {
        var request = try await makeRequest(method: "POST", path: "/v1/mutations", authenticated: true)
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try Self.jsonEncoder.encode(body)
        return try await performJSON(request)
    }

    // MARK: - Request building

    private func makeRequest(
        method: String,
        path: String,
        authenticated: Bool,
        queryItems: [URLQueryItem] = []
    ) async throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIClientError.badRequest(code: "INVALID_PATH", message: "Malformed request path: \(path)")
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIClientError.badRequest(code: "INVALID_PATH", message: "Malformed request path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            try await attachAuthorization(to: &request)
        }
        return request
    }

    private func attachAuthorization(to request: inout URLRequest) async throws {
        guard let credential = try await credentialStore.currentCredential(), !credential.isExpired() else {
            throw APIClientError.credentialsExpired
        }
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Transport

    private func performJSON<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await performRaw(request)
        do {
            return try Self.jsonDecoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decoding(message: String(describing: error))
        }
    }

    private func performJSON<T: Decodable>(_ request: URLRequest, uploadingFileAt fileURL: URL) async throws -> T {
        let (data, _) = try await performRaw(request, uploadingFileAt: fileURL)
        do {
            return try Self.jsonDecoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decoding(message: String(describing: error))
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw APIClientError.transport(message: error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.transport(message: "Response was not an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(forStatus: httpResponse.statusCode, body: data)
        }
        return (data, httpResponse)
    }

    private func performRaw(_ request: URLRequest, uploadingFileAt fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.upload(for: request, fromFile: fileURL)
        } catch {
            throw APIClientError.transport(message: error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.transport(message: "The server returned a non-HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(forStatus: httpResponse.statusCode, body: data)
        }
        return (data, httpResponse)
    }

    private static func error(forStatus status: Int, body: Data) -> APIClientError {
        let envelope = try? jsonDecoder.decode(APIErrorEnvelope.self, from: body)
        let code = envelope?.error.code ?? "UNKNOWN"
        let message = envelope?.error.message ?? String(data: body, encoding: .utf8) ?? "Unknown error"
        switch status {
        case 401: return .unauthorized(code: code, message: message)
        case 403: return .forbidden(code: code, message: message)
        case 404: return .notFound(code: code, message: message)
        case 400: return .badRequest(code: code, message: message)
        default: return .serverError(status: status, body: message)
        }
    }
}
