import Foundation
@testable import FramebaseAPIClient
import FramebaseDomain
import Testing

@Suite("Direct R2 original receive")
struct OriginalR2StoreTests {
    @Test("The development bucket URL is the only upload target")
    func developmentBucketIsRequired() throws {
        let allowed = try #require(URL(string: "https://account.r2.cloudflarestorage.com/framebase-blobs-dev/blobs/sha256/ab/hash.jpg?X-Amz-Signature=test"))
        try OriginalR2Endpoint.requireDevelopmentBucket(allowed)
        let worker = try #require(URL(string: "https://framebase-api-dev.workers.dev/v1/blobs/upload-complete"))
        #expect(throws: FramebaseAPIError.self) {
            try OriginalR2Endpoint.requireDevelopmentBucket(worker)
        }
        let production = try #require(URL(string: "https://account.r2.cloudflarestorage.com/framebase-blobs-prod/blobs/sha256/ab/hash.jpg"))
        #expect(throws: FramebaseAPIError.self) {
            try OriginalR2Endpoint.requireDevelopmentBucket(production)
        }
    }

    @Test("One direct upload records the catalog asset, and the same bytes are not uploaded again")
    func secondUploadDoesNotDuplicate() async throws {
        let transport = RecordingR2Transport()
        let store = OriginalR2Store(transport: transport)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("original-\(UUID().uuidString).jpg")
        try Data("original-bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let upload = OriginalCloudUpload(
            fileURL: file,
            sha256: String(repeating: "ab", count: 32),
            byteSize: 14,
            mediaType: "image/jpeg",
            originalExtension: "jpg",
            assetID: "11111111-1111-1111-1111-111111111111",
            displayName: "Portrait",
            librarySpace: "personal"
        )

        let first = try await store.store(upload)
        let second = try await store.store(upload)
        #expect(first == .uploaded)
        #expect(second == .alreadyInR2)
        let record = await transport.record
        #expect(record.uploadCount == 1)
        #expect(record.uploadHosts == ["account.r2.cloudflarestorage.com"])
        #expect(record.uploadPaths == ["/framebase-blobs-dev/blobs/sha256/ab/\(upload.sha256).jpg"])
        #expect(record.assetCount == 1)
        #expect(record.mutationCount == 2)
        #expect(record.workerBodyUploads == 0)
    }

    @Test("A Worker upload URL is refused before any bytes are sent")
    func workerBodyIsRefused() async throws {
        let transport = RecordingR2Transport(uploadHost: "framebase-api-dev.workers.dev", uploadPath: "/v1/blobs/upload-complete")
        let store = OriginalR2Store(transport: transport)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString).jpg")
        try Data("original-bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let upload = OriginalCloudUpload(
            fileURL: file,
            sha256: String(repeating: "cd", count: 32),
            byteSize: 14,
            mediaType: "image/jpeg",
            originalExtension: "jpg",
            assetID: "22222222-2222-2222-2222-222222222222",
            displayName: "Portrait",
            librarySpace: "personal"
        )
        await #expect(throws: FramebaseAPIError.self) {
            _ = try await store.store(upload)
        }
        let record = await transport.record
        #expect(record.uploadCount == 0)
        #expect(record.assetCount == 0)
    }
}

private actor RecordingR2Transport: OriginalR2Transport {
    struct Record: Sendable {
        var uploadCount = 0
        var uploadHosts: [String] = []
        var uploadPaths: [String] = []
        var assetCount = 0
        var mutationCount = 0
        var workerBodyUploads = 0
    }

    private let uploadHost: String
    private let uploadPath: String
    private var verified = false
    private var assets = Set<String>()
    private var state = Record()

    init(uploadHost: String = "account.r2.cloudflarestorage.com", uploadPath: String? = nil) {
        self.uploadHost = uploadHost
        self.uploadPath = uploadPath ?? ""
    }

    var record: Record { state }

    func initiateUpload(_ intent: RemoteBlobIntent) async throws -> UploadInitiation {
        if verified {
            return UploadInitiation(status: "already_verified", blobID: intent.sha256)
        }
        let path = uploadPath.isEmpty
            ? "/framebase-blobs-dev/blobs/sha256/\(intent.sha256.prefix(2))/\(intent.sha256).jpg"
            : uploadPath
        let url = try #require(URL(string: "https://\(uploadHost)\(path)?X-Amz-Signature=test"))
        let capability = DirectTransferCapability(
            url: url,
            method: "PUT",
            expiresAt: Date().addingTimeInterval(600),
            headers: ["Content-Type": intent.mediaType]
        )
        return UploadInitiation(status: "pending_upload", blobID: intent.sha256, upload: capability)
    }

    func uploadFile(_ fileURL: URL, using capability: DirectTransferCapability) async throws {
        _ = fileURL
        state.uploadCount += 1
        state.uploadHosts.append(capability.url.host ?? "")
        state.uploadPaths.append(capability.url.path)
        if capability.url.host?.contains("workers.dev") == true { state.workerBodyUploads += 1 }
        verified = true
    }

    func completeUpload(sha256: String, byteSize: Int64) async throws {
        _ = sha256
        _ = byteSize
        verified = true
    }

    func initiateMultipartUpload(_ intent: RemoteBlobIntent) async throws -> MultipartUploadInitiation {
        throw FramebaseAPIError(statusCode: 0, code: "UNUSED", message: intent.sha256)
    }

    func presignMultipartPart(uploadID: String, partNumber: Int) async throws -> DirectTransferCapability {
        throw FramebaseAPIError(statusCode: 0, code: "UNUSED", message: "\(uploadID) \(partNumber)")
    }

    func uploadPresignedPart(_ data: Data, using capability: DirectTransferCapability) async throws -> String {
        _ = data
        _ = capability
        state.workerBodyUploads += 1
        return "\"etag\""
    }

    func recordMultipartPart(uploadID: String, partNumber: Int, etag: String, byteSize: Int64) async throws {
        _ = (uploadID, partNumber, etag, byteSize)
    }

    func completeMultipartUpload(uploadID: String) async throws -> MultipartUploadCompletion {
        throw FramebaseAPIError(statusCode: 0, code: "UNUSED", message: uploadID)
    }

    func confirmMultipartUpload(uploadID: String, sha256: String, byteSize: Int64) async throws {
        _ = (uploadID, sha256, byteSize)
    }

    func applyMutation(payload: Data, idempotencyKey: String) async throws -> Data {
        state.mutationCount += 1
        let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let operations = try #require(root["operations"] as? [[String: Any]])
        let operation = try #require(operations.first)
        let assetID = try #require(operation["targetId"] as? String)
        assets.insert(assetID)
        state.assetCount = assets.count
        _ = idempotencyKey
        return Data("{}".utf8)
    }
}
