import Foundation
import FramebaseAPIClient
import FramebaseCatalog
import FramebaseDomain

public struct FixtureMigrationReport: Sendable {
    public let registeredAssetIDs: Set<AssetID>
}

public enum FixtureMigrationCoordinatorError: Error, Equatable, Sendable {
    case localBlobAssociationConflict(assetID: AssetID, existingSHA256: String, expectedSHA256: String)
    case remoteBlobIDMismatch(expected: String, received: String)
}

/// Copy-and-verify migration for fixture libraries only. It never mutates an
/// original file, storage key, or original-availability flag.
public actor FixtureMigrationCoordinator {
    private let authorization: FixtureMigrationAuthorization
    private let catalog: CatalogDatabase
    private let originalsURL: URL
    private let manifest: MigrationManifestStore
    private let apiClient: any APIClientProtocol
    private let digestService: FileDigestService
    private let progressHandler: (@Sendable (MigrationProgress) -> Void)?

    public init(authorization: FixtureMigrationAuthorization, catalog: CatalogDatabase, originalsURL: URL, manifest: MigrationManifestStore, apiClient: any APIClientProtocol, digestService: FileDigestService = FileDigestService(), progressHandler: (@Sendable (MigrationProgress) -> Void)? = nil) {
        self.authorization = authorization
        self.catalog = catalog
        self.originalsURL = originalsURL.standardizedFileURL
        self.manifest = manifest
        self.apiClient = apiClient
        self.digestService = digestService
        self.progressHandler = progressHandler
    }

    public func run() async throws -> FixtureMigrationReport {
        guard authorization.rootURL == originalsURL.deletingLastPathComponent() else { throw FixtureMigrationAuthorizationError.nonFixtureRoot(authorization.rootURL) }
        var registered = Set<AssetID>()
        var offset = 0
        while true {
            let page = try await catalog.assets.page(
                matching: AssetQuery(scope: .allAssets),
                sortedBy: .defaultSort,
                offset: offset,
                limit: 500
            )
            for record in page.records {
                try await migrate(recordID: record.id, registered: &registered)
            }
            guard page.hasMore, !page.records.isEmpty else { break }
            offset += page.records.count
        }
        return FixtureMigrationReport(registeredAssetIDs: registered)
    }

    private func migrate(recordID: AssetID, registered: inout Set<AssetID>) async throws {
        guard let asset = try await catalog.assets.asset(id: recordID) else { return }
        let existingEntry = try await manifest.entry(for: asset.id)
        if existingEntry?.state == .registered {
            registered.insert(asset.id)
            return
        }
        if existingEntry == nil {
            try await persist(MigrationManifestEntry(
                assetID: asset.id,
                storageKey: asset.storageKey.rawValue,
                byteSize: asset.fileSize,
                sha256: nil,
                remoteBlobID: nil,
                remoteAssetID: nil,
                state: .inventoried,
                retryCount: 0,
                lastError: nil
            ))
        }

        do {
        let originalURL = originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory).standardizedFileURL
        let extensionName = originalURL.pathExtension.lowercased()
        let retryCount = existingEntry?.retryCount ?? 0
        let remote: (sha256: String, byteSize: Int64, blobID: String, r2Key: String)
        if let entry = existingEntry,
           entry.state == .verified,
           let sha256 = entry.sha256,
           let blobID = entry.remoteBlobID,
           let r2Key = entry.remoteR2Key {
            remote = (sha256, entry.byteSize, blobID, r2Key)
        } else if let entry = existingEntry,
                  entry.state == .uploaded,
                  let sha256 = entry.sha256,
                  let blobID = entry.remoteBlobID,
                  let r2Key = entry.remoteR2Key {
            let completed = try await apiClient.completeBlobUpload(
                BlobUploadCompleteRequest(sha256: sha256, byteSize: Int(entry.byteSize))
            )
            guard completed.blobId == blobID else {
                throw FixtureMigrationCoordinatorError.remoteBlobIDMismatch(expected: blobID, received: completed.blobId)
            }
            try await persist(MigrationManifestEntry(
                assetID: asset.id,
                storageKey: asset.storageKey.rawValue,
                byteSize: entry.byteSize,
                sha256: sha256,
                remoteBlobID: completed.blobId,
                remoteR2Key: r2Key,
                remoteAssetID: nil,
                state: .verified,
                retryCount: retryCount,
                lastError: nil
            ))
            remote = (sha256, entry.byteSize, completed.blobId, r2Key)
        } else {
            let digest = try await digestService.digest(at: originalURL)
            try await persist(MigrationManifestEntry(assetID: asset.id, storageKey: asset.storageKey.rawValue, byteSize: digest.byteSize, sha256: digest.sha256, remoteBlobID: nil, remoteAssetID: nil, state: .hashed, retryCount: retryCount, lastError: nil))
            let initiated = try await apiClient.initiateBlobUpload(BlobUploadInitiateRequest(sha256: digest.sha256, byteSize: Int(digest.byteSize), mediaType: "image/jpeg", originalExtension: extensionName))
            _ = try await apiClient.uploadBlobFile(at: originalURL, contentType: "image/jpeg", toRelativePath: initiated.uploadUrl)
            try await persist(MigrationManifestEntry(assetID: asset.id, storageKey: asset.storageKey.rawValue, byteSize: digest.byteSize, sha256: digest.sha256, remoteBlobID: initiated.blobId, remoteR2Key: initiated.r2Key, remoteAssetID: nil, state: .uploaded, retryCount: retryCount, lastError: nil))
            let completed = try await apiClient.completeBlobUpload(BlobUploadCompleteRequest(sha256: digest.sha256, byteSize: Int(digest.byteSize)))
            try await persist(MigrationManifestEntry(assetID: asset.id, storageKey: asset.storageKey.rawValue, byteSize: digest.byteSize, sha256: digest.sha256, remoteBlobID: completed.blobId, remoteR2Key: initiated.r2Key, remoteAssetID: nil, state: .verified, retryCount: retryCount, lastError: nil))
            remote = (digest.sha256, digest.byteSize, completed.blobId, initiated.r2Key)
        }

        if try await catalog.blobs.blob(sha256: remote.sha256) == nil {
            try await catalog.blobs.register(Blob(sha256: remote.sha256, byteSize: remote.byteSize, mediaType: "image/jpeg", originalExtension: extensionName, r2Key: remote.r2Key, uploadState: .verified, verificationETag: nil, verifiedAt: Date(), createdAt: Date()))
        }
        if let existingSHA256 = try await catalog.blobs.blobSHA256(for: asset.id) {
            guard existingSHA256 == remote.sha256 else {
                throw FixtureMigrationCoordinatorError.localBlobAssociationConflict(assetID: asset.id, existingSHA256: existingSHA256, expectedSHA256: remote.sha256)
            }
        } else {
            try await catalog.blobs.link(assetID: asset.id, toBlobSHA256: remote.sha256)
        }
        let date = ISO8601DateFormatter().string(from: asset.createdAt)
        let metadataData = try JSONEncoder().encode(asset.metadata)
        let metadata = try JSONDecoder().decode(JSONValue.self, from: metadataData)
        let registration = AssetRegistrationRequest(clientMutationId: "fixture-\(asset.id.description)", assetId: asset.id.description, blobId: remote.blobID, folderId: asset.parentFolderID.description, filename: asset.filename, displayName: asset.displayName, width: asset.width, height: asset.height, createdAt: date, modifiedAt: ISO8601DateFormatter().string(from: asset.modifiedAt), importedAt: ISO8601DateFormatter().string(from: asset.importedAt), favorite: asset.favorite, rating: asset.rating.rawValue, metadata: metadata)
        _ = try await apiClient.registerAsset(registration, idempotencyKey: registration.clientMutationId)
        try await persist(MigrationManifestEntry(assetID: asset.id, storageKey: asset.storageKey.rawValue, byteSize: remote.byteSize, sha256: remote.sha256, remoteBlobID: remote.blobID, remoteR2Key: remote.r2Key, remoteAssetID: asset.id.description, state: .registered, retryCount: retryCount, lastError: nil))
        registered.insert(asset.id)
        } catch {
            let latestEntry = (try? await manifest.entry(for: asset.id)) ?? existingEntry
            let wasCancelled = error is CancellationError
            let failureEntry = MigrationManifestEntry(
                assetID: asset.id,
                storageKey: asset.storageKey.rawValue,
                byteSize: latestEntry?.byteSize ?? asset.fileSize,
                sha256: latestEntry?.sha256,
                remoteBlobID: latestEntry?.remoteBlobID,
                remoteR2Key: latestEntry?.remoteR2Key,
                remoteAssetID: latestEntry?.remoteAssetID,
                state: wasCancelled ? .cancelled : .failed,
                retryCount: (latestEntry?.retryCount ?? 0) + 1,
                lastError: wasCancelled ? "Migration cancelled" : error.localizedDescription
            )
            try await Task.detached(priority: .utility) { [manifest] in
                try await manifest.upsert(failureEntry)
            }.value
            progressHandler?(MigrationProgress(assetID: failureEntry.assetID, state: failureEntry.state, retryCount: failureEntry.retryCount))
            throw error
        }
    }

    private func persist(_ entry: MigrationManifestEntry) async throws {
        try await manifest.upsert(entry)
        progressHandler?(MigrationProgress(assetID: entry.assetID, state: entry.state, retryCount: entry.retryCount))
    }
}
