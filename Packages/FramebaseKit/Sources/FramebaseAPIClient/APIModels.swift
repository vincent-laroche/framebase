import Foundation

/// A minimal dynamic JSON value, used for change-feed and mutation payloads whose
/// shape varies by entity/operation type and is not fixed by the wire contract.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// Parses the ISO 8601 timestamps `Cloud/apps/api` emits (`Date().toISOString()`,
/// which always includes millisecond fractional seconds).
public enum ISO8601Coding {
    public static func parse(_ string: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date
        }

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        return withoutFractionalSeconds.date(from: string)
    }
}

// MARK: - Health

public struct HealthResponse: Codable, Equatable, Sendable {
    public let status: String
    public let environment: String
    public let version: String
    public let db: String
    public let timestamp: String

    public init(status: String, environment: String, version: String, db: String, timestamp: String) {
        self.status = status
        self.environment = environment
        self.version = version
        self.db = db
        self.timestamp = timestamp
    }
}

// MARK: - Enrollment

public struct EnrollRequest: Codable, Equatable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let publicKey: String
    public let scopes: [String]?

    public init(deviceId: String, deviceName: String, publicKey: String, scopes: [String]? = nil) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.scopes = scopes
    }
}

public struct EnrollResponse: Codable, Equatable, Sendable {
    public let status: String
    public let deviceId: String
    public let scopes: [String]
    public let token: String
    public let expiresAt: String

    public init(status: String, deviceId: String, scopes: [String], token: String, expiresAt: String) {
        self.status = status
        self.deviceId = deviceId
        self.scopes = scopes
        self.token = token
        self.expiresAt = expiresAt
    }
}

// MARK: - Change feed

public struct ChangeEvent: Codable, Equatable, Sendable {
    public let revision: Int
    public let entityType: String
    public let entityId: String
    public let operation: String
    public let payload: JSONValue
    public let actorId: String
    public let clientMutationId: String?
    public let createdAt: String

    public init(
        revision: Int,
        entityType: String,
        entityId: String,
        operation: String,
        payload: JSONValue,
        actorId: String,
        clientMutationId: String?,
        createdAt: String
    ) {
        self.revision = revision
        self.entityType = entityType
        self.entityId = entityId
        self.operation = operation
        self.payload = payload
        self.actorId = actorId
        self.clientMutationId = clientMutationId
        self.createdAt = createdAt
    }
}

public struct ChangesCursor: Codable, Equatable, Sendable {
    public let after: Int
    public let lastRevision: Int
    public let hasMore: Bool

    public init(after: Int, lastRevision: Int, hasMore: Bool) {
        self.after = after
        self.lastRevision = lastRevision
        self.hasMore = hasMore
    }
}

public struct ChangesResponse: Codable, Equatable, Sendable {
    public let changes: [ChangeEvent]
    public let cursor: ChangesCursor

    public init(changes: [ChangeEvent], cursor: ChangesCursor) {
        self.changes = changes
        self.cursor = cursor
    }
}

// MARK: - Blobs

public struct BlobUploadInitiateRequest: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteSize: Int
    public let mediaType: String
    public let originalExtension: String

    public init(sha256: String, byteSize: Int, mediaType: String, originalExtension: String) {
        self.sha256 = sha256
        self.byteSize = byteSize
        self.mediaType = mediaType
        self.originalExtension = originalExtension
    }
}

public struct BlobUploadInitiateResponse: Codable, Equatable, Sendable {
    public let blobId: String
    public let r2Key: String
    public let uploadUrl: String
    public let expiresAt: String

    public init(blobId: String, r2Key: String, uploadUrl: String, expiresAt: String) {
        self.blobId = blobId
        self.r2Key = r2Key
        self.uploadUrl = uploadUrl
        self.expiresAt = expiresAt
    }
}

public struct BlobUploadDirectResponse: Codable, Equatable, Sendable {
    public let status: String
    public let key: String
    public let size: Int

    public init(status: String, key: String, size: Int) {
        self.status = status
        self.key = key
        self.size = size
    }
}

public struct BlobUploadCompleteRequest: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteSize: Int

    public init(sha256: String, byteSize: Int) {
        self.sha256 = sha256
        self.byteSize = byteSize
    }
}

public struct BlobUploadCompleteResponse: Codable, Equatable, Sendable {
    public let status: String
    public let blobId: String
    public let size: Int

    public init(status: String, blobId: String, size: Int) {
        self.status = status
        self.blobId = blobId
        self.size = size
    }
}

public struct BlobDownload: Equatable, Sendable {
    public let data: Data
    public let contentType: String?
    public let etag: String?
}

// MARK: - Asset registration

public struct AssetRegistrationRequest: Codable, Equatable, Sendable {
    public let clientMutationId: String
    public let assetId: String
    public let blobId: String
    public let folderId: String
    public let filename: String
    public let displayName: String
    public let width: Int?
    public let height: Int?
    public let createdAt: String
    public let modifiedAt: String
    public let importedAt: String
    public let favorite: Bool
    public let rating: Int
    public let metadata: JSONValue

    public init(clientMutationId: String, assetId: String, blobId: String, folderId: String, filename: String, displayName: String, width: Int?, height: Int?, createdAt: String, modifiedAt: String, importedAt: String, favorite: Bool, rating: Int, metadata: JSONValue) {
        self.clientMutationId = clientMutationId
        self.assetId = assetId
        self.blobId = blobId
        self.folderId = folderId
        self.filename = filename
        self.displayName = displayName
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.importedAt = importedAt
        self.favorite = favorite
        self.rating = rating
        self.metadata = metadata
    }
}

public struct AssetRegistrationResponse: Codable, Equatable, Sendable {
    public let status: String
    public let assetId: String
    public let blobId: String
    public let revision: Int

    public init(status: String, assetId: String, blobId: String, revision: Int) {
        self.status = status
        self.assetId = assetId
        self.blobId = blobId
        self.revision = revision
    }
}

// MARK: - Mutations

public enum MutationOperationType: String, Codable, Equatable, Sendable {
    case createFolder = "create_folder"
    case renameFolder = "rename_folder"
    case moveAssets = "move_assets"
    case updateRating = "update_rating"
    case updateFavorite = "update_favorite"
}

public struct MutationOperation: Codable, Equatable, Sendable {
    public let type: MutationOperationType
    public let targetId: String
    public let payload: JSONValue

    public init(type: MutationOperationType, targetId: String, payload: JSONValue) {
        self.type = type
        self.targetId = targetId
        self.payload = payload
    }
}

public struct MutationsRequest: Codable, Equatable, Sendable {
    public let clientMutationId: String
    public let actorId: String
    public let operations: [MutationOperation]

    public init(clientMutationId: String, actorId: String, operations: [MutationOperation]) {
        self.clientMutationId = clientMutationId
        self.actorId = actorId
        self.operations = operations
    }
}

public struct MutationResult: Codable, Equatable, Sendable {
    public let targetId: String
    public let revision: Int

    public init(targetId: String, revision: Int) {
        self.targetId = targetId
        self.revision = revision
    }
}

public struct MutationsResponse: Codable, Equatable, Sendable {
    public let status: String
    public let clientMutationId: String
    public let appliedCount: Int
    public let results: [MutationResult]

    public init(status: String, clientMutationId: String, appliedCount: Int, results: [MutationResult]) {
        self.status = status
        self.clientMutationId = clientMutationId
        self.appliedCount = appliedCount
        self.results = results
    }
}

// MARK: - Error envelope

struct APIErrorEnvelope: Codable {
    struct Body: Codable {
        let code: String
        let message: String
    }

    let error: Body
}
