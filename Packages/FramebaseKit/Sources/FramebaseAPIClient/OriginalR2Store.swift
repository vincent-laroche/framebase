import Foundation
import FramebaseDomain

/// Limits and the only bucket this receive path is allowed to write.
public enum OriginalR2Endpoint {
    public static let bucketName = "framebase-blobs-dev"
    /// R2 PutObject maximum. Larger originals use presigned multipart parts.
    public static let singlePutMaximumBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    public static let objectMaximumBytes: Int64 = 5 * 1_024 * 1_024 * 1_024 * 1_024

    public static func requireDevelopmentBucket(_ url: URL) throws {
        try FramebaseAPIClient.requireDevelopmentBucket(url)
    }
}

public struct OriginalCloudUpload: Sendable {
    public let fileURL: URL
    public let sha256: String
    public let byteSize: Int64
    public let mediaType: String
    public let originalExtension: String
    public let assetID: String
    public let displayName: String
    public let librarySpace: String

    public init(
        fileURL: URL,
        sha256: String,
        byteSize: Int64,
        mediaType: String,
        originalExtension: String,
        assetID: String,
        displayName: String,
        librarySpace: String
    ) {
        self.fileURL = fileURL
        self.sha256 = sha256
        self.byteSize = byteSize
        self.mediaType = mediaType
        self.originalExtension = originalExtension
        self.assetID = assetID
        self.displayName = displayName
        self.librarySpace = librarySpace
    }
}

public protocol OriginalR2Transport: Sendable {
    func initiateUpload(_ intent: RemoteBlobIntent) async throws -> UploadInitiation
    func uploadFile(_ fileURL: URL, using capability: DirectTransferCapability) async throws
    func completeUpload(sha256: String, byteSize: Int64) async throws
    func initiateMultipartUpload(_ intent: RemoteBlobIntent) async throws -> MultipartUploadInitiation
    func presignMultipartPart(uploadID: String, partNumber: Int) async throws -> DirectTransferCapability
    func uploadPresignedPart(_ data: Data, using capability: DirectTransferCapability) async throws -> String
    func recordMultipartPart(uploadID: String, partNumber: Int, etag: String, byteSize: Int64) async throws
    func completeMultipartUpload(uploadID: String) async throws -> MultipartUploadCompletion
    func confirmMultipartUpload(uploadID: String, sha256: String, byteSize: Int64) async throws
    func applyMutation(payload: Data, idempotencyKey: String) async throws -> Data
}

extension FramebaseAPIClient: OriginalR2Transport {}

/// Puts original bytes straight at a presigned `framebase-blobs-dev` URL, then writes one catalog asset.
public struct OriginalR2Store: Sendable {
    private let transport: any OriginalR2Transport

    public init(transport: any OriginalR2Transport) {
        self.transport = transport
    }

    public func store(_ upload: OriginalCloudUpload) async throws -> OriginalBlobDisposition {
        guard upload.byteSize > 0, upload.byteSize <= OriginalR2Endpoint.objectMaximumBytes else {
            throw FramebaseAPIError(statusCode: 422, code: "INVALID_BLOB_INTENT", message: "Original size is outside the R2 object limit")
        }
        let intent = RemoteBlobIntent(
            sha256: upload.sha256,
            byteSize: upload.byteSize,
            mediaType: upload.mediaType,
            originalExtension: upload.originalExtension
        )
        let disposition: OriginalBlobDisposition
        if upload.byteSize <= OriginalR2Endpoint.singlePutMaximumBytes {
            disposition = try await storeSinglePart(upload, intent: intent)
        } else {
            disposition = try await storeMultipart(upload, intent: intent)
        }
        try await recordCatalogAsset(upload)
        return disposition
    }

    private func storeSinglePart(_ upload: OriginalCloudUpload, intent: RemoteBlobIntent) async throws -> OriginalBlobDisposition {
        let initiation = try await transport.initiateUpload(intent)
        if initiation.status == "already_verified" { return .alreadyInR2 }
        guard let capability = initiation.upload else {
            throw FramebaseAPIError(statusCode: 0, code: "DIRECT_R2_REQUIRED", message: "Upload initiation did not return a direct R2 URL")
        }
        try OriginalR2Endpoint.requireDevelopmentBucket(capability.url)
        try await transport.uploadFile(upload.fileURL, using: capability)
        try await transport.completeUpload(sha256: upload.sha256, byteSize: upload.byteSize)
        return .uploaded
    }

    private func storeMultipart(_ upload: OriginalCloudUpload, intent: RemoteBlobIntent) async throws -> OriginalBlobDisposition {
        let initiation = try await transport.initiateMultipartUpload(intent)
        if initiation.status == "already_verified" { return .alreadyInR2 }
        guard let uploadID = initiation.uploadID, let partByteSize = initiation.partByteSize, let partCount = initiation.partCount,
              partByteSize > 0, partCount > 0 else {
            throw FramebaseAPIError(statusCode: 0, code: "INVALID_MULTIPART_RESPONSE", message: "API did not return a valid multipart manifest")
        }
        let uploadedPartNumbers = Set(initiation.uploadedParts.map(\.partNumber))
        let handle = try FileHandle(forReadingFrom: upload.fileURL)
        defer { try? handle.close() }
        for partNumber in 1...partCount where !uploadedPartNumbers.contains(partNumber) {
            let offset = UInt64(partNumber - 1) * UInt64(partByteSize)
            try handle.seek(toOffset: offset)
            let expectedByteCount = partNumber == partCount
                ? Int(upload.byteSize - Int64(partByteSize) * Int64(partCount - 1))
                : partByteSize
            let data = try handle.read(upToCount: expectedByteCount) ?? Data()
            guard data.count == expectedByteCount else {
                throw FramebaseAPIError(statusCode: 422, code: "INVALID_PART_SIZE", message: "Local part did not match the upload manifest")
            }
            let capability = try await transport.presignMultipartPart(uploadID: uploadID, partNumber: partNumber)
            try OriginalR2Endpoint.requireDevelopmentBucket(capability.url)
            let etag = try await transport.uploadPresignedPart(data, using: capability)
            try await transport.recordMultipartPart(uploadID: uploadID, partNumber: partNumber, etag: etag, byteSize: Int64(data.count))
        }
        _ = try await transport.completeMultipartUpload(uploadID: uploadID)
        try await transport.confirmMultipartUpload(uploadID: uploadID, sha256: upload.sha256, byteSize: upload.byteSize)
        return .uploaded
    }

    private func recordCatalogAsset(_ upload: OriginalCloudUpload) async throws {
        let displayName = String(upload.displayName.prefix(160))
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Original" : displayName
        let body: [String: Any] = [
            "clientMutationId": "receive-asset-\(upload.assetID)",
            "operations": [[
                "type": "create_asset",
                "targetId": upload.assetID,
                "payload": [
                    "blobId": upload.sha256,
                    "folderId": "system-inbox",
                    "displayName": name,
                    "assetMetadata": [
                        "librarySpace": upload.librarySpace,
                        "mediaType": "stillImage"
                    ]
                ]
            ]]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        _ = try await transport.applyMutation(payload: payload, idempotencyKey: "receive-asset-\(upload.assetID)")
    }
}
