import FramebaseAPIClient
import Foundation
import Testing

private let stubBaseURL = URL(string: "https://framebase-api-dev.example")!

private final class InMemoryCredentialStore: DeviceCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: StoredDeviceCredential?

    init(credential: StoredDeviceCredential? = nil) {
        self.credential = credential
    }

    func currentCredential() async throws -> StoredDeviceCredential? {
        lock.withLock { credential }
    }

    func store(_ credential: StoredDeviceCredential) async throws {
        lock.withLock { self.credential = credential }
    }

    func clear() async throws {
        lock.withLock { credential = nil }
    }
}

/// Captures requests seen by `StubURLProtocol` for later inspection back in
/// the test body. `URLProtocol.startLoading()` runs off the test's Task tree,
/// so Swift Testing's `#expect`/`Issue.record` cannot reliably attribute
/// there — this recorder is a plain thread-safe box with no assertions of
/// its own, and every assertion happens after the awaited call returns.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var last: URLRequest? {
        lock.withLock { requests.last }
    }

    var all: [URLRequest] {
        lock.withLock { requests }
    }
}

/// Stubs `URLSession` at the protocol layer. Tests run serialized within this
/// suite (see `.serialized` below) so the single mutable handler is safe.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? stubBaseURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeClient(
    credential: StoredDeviceCredential? = StoredDeviceCredential(
        deviceId: "device-1",
        token: "token-1",
        expiresAt: Date().addingTimeInterval(3_600)
    )
) -> (client: FramebaseAPIClient, store: InMemoryCredentialStore) {
    let store = InMemoryCredentialStore(credential: credential)
    let client = FramebaseAPIClient(baseURL: stubBaseURL, credentialStore: store, urlSession: makeSession())
    return (client, store)
}

private func jsonBody<T: Encodable>(_ value: T) -> Data {
    try! JSONEncoder().encode(value)
}

private func errorBody(code: String, message: String) -> Data {
    Data("""
    {"error":{"code":"\(code)","message":"\(message)"}}
    """.utf8)
}

/// Records every request seen and always answers with `response`.
private func respondingHandler(
    with response: (Int, [String: String], Data),
    recorder: RequestRecorder
) -> @Sendable (URLRequest) -> (Int, [String: String], Data) {
    { request in
        recorder.record(request)
        return response
    }
}

@Suite("FramebaseAPIClient", .serialized)
struct FramebaseAPIClientTests {
    @Test("health() decodes the public health response")
    func healthSucceeds() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (200, ["Content-Type": "application/json"], jsonBody(HealthResponse(
                status: "ok",
                environment: "development",
                version: "0.1.0",
                db: "ok",
                timestamp: "2026-08-09T12:00:00.000Z"
            ))),
            recorder: recorder
        )

        let response = try await client.health()
        #expect(response.status == "ok")
        #expect(response.db == "ok")
        #expect(recorder.last?.url?.path == "/v1/health")
        #expect(recorder.last?.httpMethod == "GET")
    }

    @Test("enroll() sends the enrollment secret header and decodes the token")
    func enrollSucceeds() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (200, [:], jsonBody(EnrollResponse(
                status: "enrolled",
                deviceId: "device-1",
                scopes: ["library.read"],
                token: "jwt-token",
                expiresAt: "2026-08-09T13:00:00.000Z"
            ))),
            recorder: recorder
        )

        let response = try await client.enroll(
            enrollmentSecret: "shh",
            request: EnrollRequest(deviceId: "device-1", deviceName: "Test Mac", publicKey: "pk")
        )
        #expect(response.token == "jwt-token")
        #expect(response.scopes == ["library.read"])
        #expect(recorder.last?.url?.path == "/v1/auth/enroll")
        #expect(recorder.last?.value(forHTTPHeaderField: "X-Enrollment-Secret") == "shh")
    }

    @Test("enroll() with a bad secret surfaces as unauthorized with the server's code")
    func enrollRejectsBadSecret() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (401, [:], errorBody(code: "UNAUTHORIZED", message: "Invalid or missing enrollment secret")),
            recorder: recorder
        )

        await #expect(throws: APIClientError.unauthorized(
            code: "UNAUTHORIZED",
            message: "Invalid or missing enrollment secret"
        )) {
            try await client.enroll(
                enrollmentSecret: "wrong",
                request: EnrollRequest(deviceId: "device-1", deviceName: "Test Mac", publicKey: "pk")
            )
        }
    }

    @Test("fetchChanges() attaches the bearer token and decodes a heterogeneous payload")
    func fetchChangesSucceeds() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (200, [:], jsonBody(ChangesResponse(
                changes: [
                    ChangeEvent(
                        revision: 6,
                        entityType: "folder",
                        entityId: "folder-1",
                        operation: "create",
                        payload: .object(["name": .string("Vacation")]),
                        actorId: "device-1",
                        clientMutationId: "mutation-1_folder-1",
                        createdAt: "2026-08-09T12:00:00.000Z"
                    )
                ],
                cursor: ChangesCursor(after: 5, lastRevision: 6, hasMore: false)
            ))),
            recorder: recorder
        )

        let response = try await client.fetchChanges(after: 5, limit: 100)
        #expect(response.changes.count == 1)
        #expect(response.cursor.hasMore == false)
        if case .object(let fields) = response.changes[0].payload {
            #expect(fields["name"] == .string("Vacation"))
        } else {
            Issue.record("Expected an object payload")
        }
        #expect(recorder.last?.url?.path == "/v1/changes")
        #expect(recorder.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(recorder.last?.url?.query?.contains("after=5") == true)
    }

    @Test("An authenticated call without a stored credential throws credentialsExpired before any request is sent")
    func missingCredentialThrowsWithoutNetworkCall() async throws {
        let (client, _) = makeClient(credential: nil)
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (599, [:], Data("unexpected network call".utf8)),
            recorder: recorder
        )

        await #expect(throws: APIClientError.credentialsExpired) {
            _ = try await client.fetchChanges(after: 0, limit: 100)
        }
        #expect(recorder.all.isEmpty)
    }

    @Test("An expired stored credential throws credentialsExpired before any request is sent")
    func expiredCredentialThrowsWithoutNetworkCall() async throws {
        let expired = StoredDeviceCredential(
            deviceId: "device-1",
            token: "token-1",
            expiresAt: Date().addingTimeInterval(-10)
        )
        let (client, _) = makeClient(credential: expired)
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (599, [:], Data("unexpected network call".utf8)),
            recorder: recorder
        )

        await #expect(throws: APIClientError.credentialsExpired) {
            _ = try await client.fetchChanges(after: 0, limit: 100)
        }
        #expect(recorder.all.isEmpty)
    }

    @Test("submitMutations() sends the Idempotency-Key header and decodes applied results")
    func submitMutationsSucceeds() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (200, [:], jsonBody(MutationsResponse(
                status: "applied",
                clientMutationId: "mutation-1",
                appliedCount: 1,
                results: [MutationResult(targetId: "folder-1", revision: 6)]
            ))),
            recorder: recorder
        )

        let response = try await client.submitMutations(
            MutationsRequest(
                clientMutationId: "mutation-1",
                actorId: "device-1",
                operations: [
                    MutationOperation(
                        type: .createFolder,
                        targetId: "folder-1",
                        payload: .object(["name": .string("Vacation")])
                    )
                ]
            ),
            idempotencyKey: "mutation-1"
        )
        #expect(response.appliedCount == 1)
        #expect(response.results.first?.revision == 6)
        #expect(recorder.last?.value(forHTTPHeaderField: "Idempotency-Key") == "mutation-1")
    }

    @Test("submitMutations() missing a required scope surfaces as forbidden")
    func submitMutationsForbidden() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (403, [:], errorBody(code: "FORBIDDEN", message: "Missing required scope(s): assets.organize")),
            recorder: recorder
        )

        await #expect(throws: APIClientError.forbidden(
            code: "FORBIDDEN",
            message: "Missing required scope(s): assets.organize"
        )) {
            _ = try await client.submitMutations(
                MutationsRequest(
                    clientMutationId: "mutation-1",
                    actorId: "device-1",
                    operations: [MutationOperation(type: .createFolder, targetId: "folder-1", payload: .null)]
                ),
                idempotencyKey: "mutation-1"
            )
        }
    }

    @Test("registerAsset() sends the idempotency key and typed asset payload")
    func registerAssetSucceeds() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (200, [:], jsonBody(AssetRegistrationResponse(
                status: "registered",
                assetId: "asset-1",
                blobId: "blob-1",
                revision: 7
            ))),
            recorder: recorder
        )

        let response = try await client.registerAsset(
            AssetRegistrationRequest(
                clientMutationId: "register-asset-1",
                assetId: "asset-1",
                blobId: "blob-1",
                folderId: "folder-1",
                filename: "fixture.jpg",
                displayName: "Fixture",
                width: 2,
                height: 2,
                createdAt: "2026-08-09T12:00:00.000Z",
                modifiedAt: "2026-08-09T12:00:00.000Z",
                importedAt: "2026-08-09T12:00:00.000Z",
                favorite: false,
                rating: 0,
                metadata: .object(["source": .string("fixture")])
            ),
            idempotencyKey: "register-asset-1"
        )

        #expect(response.revision == 7)
        #expect(recorder.last?.url?.path == "/v1/assets/register")
        #expect(recorder.last?.httpMethod == "POST")
        #expect(recorder.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(recorder.last?.value(forHTTPHeaderField: "Idempotency-Key") == "register-asset-1")
    }

    @Test("The full blob upload flow initiates, PUTs a file to the returned relative path, then completes")
    func blobUploadFlowSucceeds() async throws {
        let (client, _) = makeClient()
        let payload = Data("fixture-bytes".utf8)
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "FramebaseAPIClientTests-\(UUID().uuidString).jpg", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try payload.write(to: fileURL, options: .atomic)
        let recorder = RequestRecorder()

        StubURLProtocol.handler = { request in
            recorder.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/blobs/upload-initiate"):
                return (200, [:], jsonBody(BlobUploadInitiateResponse(
                    blobId: "sha-1",
                    r2Key: "blobs/sha256/sh/sha-1.jpg",
                    uploadUrl: "/v1/blobs/upload-direct?blobId=sha-1",
                    expiresAt: "2026-08-09T12:15:00.000Z"
                )))
            case ("PUT", "/v1/blobs/upload-direct"):
                return (200, [:], jsonBody(BlobUploadDirectResponse(
                    status: "uploaded",
                    key: "blobs/sha256/sh/sha-1.jpg",
                    size: payload.count
                )))
            case ("POST", "/v1/blobs/upload-complete"):
                return (200, [:], jsonBody(BlobUploadCompleteResponse(status: "verified", blobId: "sha-1", size: payload.count)))
            default:
                return (599, [:], Data("unexpected request: \(request.httpMethod ?? "?") \(request.url?.path ?? "?")".utf8))
            }
        }

        let initiated = try await client.initiateBlobUpload(
            BlobUploadInitiateRequest(sha256: "sha-1", byteSize: payload.count, mediaType: "image/jpeg", originalExtension: "jpg")
        )
        let uploaded = try await client.uploadBlobFile(
            at: fileURL,
            contentType: "image/jpeg",
            toRelativePath: initiated.uploadUrl
        )
        #expect(uploaded.status == "uploaded")

        let completed = try await client.completeBlobUpload(
            BlobUploadCompleteRequest(sha256: "sha-1", byteSize: payload.count)
        )
        #expect(completed.status == "verified")

        let uploadRequest = recorder.all.first { $0.httpMethod == "PUT" }
        #expect(uploadRequest?.url?.query == "blobId=sha-1")
        #expect(uploadRequest?.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
    }

    @Test("downloadBlob() returns raw bytes with content-type and etag on success")
    func downloadBlobSucceeds() async throws {
        let (client, _) = makeClient()
        let payload = Data("fixture-bytes".utf8)
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (200, ["Content-Type": "image/jpeg", "etag": "\"abc123\""], payload),
            recorder: recorder
        )

        let download = try await client.downloadBlob(id: "sha-1")
        #expect(download.data == payload)
        #expect(download.contentType == "image/jpeg")
        #expect(download.etag == "\"abc123\"")
        #expect(recorder.last?.url?.path == "/v1/blobs/sha-1/download")
    }

    @Test("downloadBlob() for an unknown id surfaces the server's not-found code")
    func downloadBlobNotFound() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (404, [:], errorBody(code: "BLOB_NOT_FOUND", message: "Blob not found")),
            recorder: recorder
        )

        await #expect(throws: APIClientError.notFound(code: "BLOB_NOT_FOUND", message: "Blob not found")) {
            _ = try await client.downloadBlob(id: "missing")
        }
    }

    @Test("A server error without a recognizable status maps to serverError")
    func unrecognizedStatusMapsToServerError() async throws {
        let (client, _) = makeClient()
        let recorder = RequestRecorder()
        StubURLProtocol.handler = respondingHandler(
            with: (500, [:], errorBody(code: "SERVER_MISCONFIGURED", message: "JWT_SECRET is not configured")),
            recorder: recorder
        )

        await #expect(throws: APIClientError.serverError(
            status: 500,
            body: "JWT_SECRET is not configured"
        )) {
            _ = try await client.fetchChanges(after: 0, limit: 100)
        }
    }
}
