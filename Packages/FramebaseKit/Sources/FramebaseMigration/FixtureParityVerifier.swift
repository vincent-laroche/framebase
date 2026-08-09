import Foundation
import FramebaseCatalog
import FramebaseDomain

/// A typed, fixture-only representation of the canonical remote state used to
/// prove that a clean local catalog can be reconstructed without replaying the
/// source catalog or reading a user library.
public struct FixtureRemoteCatalogSnapshot: Sendable {
    public let folders: [Folder]
    public let blobs: [Blob]
    public let assets: [FixtureRemoteAsset]

    public init(folders: [Folder], blobs: [Blob], assets: [FixtureRemoteAsset]) {
        self.folders = folders
        self.blobs = blobs
        self.assets = assets
    }
}

public struct FixtureRemoteAsset: Sendable {
    public let id: AssetID
    public let blobSHA256: String
    public let folderID: FolderID
    public let filename: String
    public let displayName: String
    public let width: Int?
    public let height: Int?
    public let createdAt: Date
    public let modifiedAt: Date
    public let importedAt: Date
    public let favorite: Bool
    public let rating: AssetRating
    public let metadata: AssetMetadata

    public init(id: AssetID, blobSHA256: String, folderID: FolderID, filename: String, displayName: String, width: Int?, height: Int?, createdAt: Date, modifiedAt: Date, importedAt: Date, favorite: Bool, rating: AssetRating, metadata: AssetMetadata) {
        self.id = id
        self.blobSHA256 = blobSHA256
        self.folderID = folderID
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

public struct FixtureParityReport: Equatable, Sendable {
    public let mismatches: [String]

    public init(mismatches: [String]) { self.mismatches = mismatches }
    public var isEquivalent: Bool { mismatches.isEmpty }
}

public enum FixtureParityVerifier {
    /// Creates a new catalog from only typed remote records. It does not open
    /// or replay the source catalog and never creates or deletes originals.
    public static func rebuildCatalog(from snapshot: FixtureRemoteCatalogSnapshot, at catalogURL: URL) async throws -> CatalogDatabase {
        let catalog = try CatalogDatabase(catalogURL: catalogURL)
        for folder in snapshot.folders.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            _ = try await catalog.folders.createFolder(id: folder.id, named: folder.name, in: folder.parentFolderID)
        }
        let blobsBySHA = Dictionary(uniqueKeysWithValues: snapshot.blobs.map { ($0.sha256, $0) })
        for blob in snapshot.blobs {
            try await catalog.blobs.register(blob)
        }
        let assets = try snapshot.assets.map { remote -> Asset in
            guard let blob = blobsBySHA[remote.blobSHA256] else {
                throw FixtureParityVerifierError.missingBlob(assetID: remote.id, sha256: remote.blobSHA256)
            }
            let extensionName = remote.filename.split(separator: ".").last.map(String.init) ?? blob.originalExtension
            let storageKey = try AssetStorageKey("\(String(remote.id.description.prefix(2)))/\(remote.id.description).\(extensionName)")
            return Asset(
                id: remote.id,
                filename: remote.filename,
                displayName: remote.displayName,
                parentFolderID: remote.folderID,
                storageKey: storageKey,
                fileSize: blob.byteSize,
                createdAt: remote.createdAt,
                modifiedAt: remote.modifiedAt,
                importedAt: remote.importedAt,
                updatedAt: remote.importedAt,
                favorite: remote.favorite,
                rating: remote.rating,
                metadata: remote.metadata
            )
        }
        try await catalog.insertAssets(assets)
        for remote in snapshot.assets {
            try await catalog.blobs.link(assetID: remote.id, toBlobSHA256: remote.blobSHA256)
        }
        return catalog
    }

    public static func compare(sourceAssets: [Asset], sourceBlobSHA256: [AssetID: String], rebuiltCatalog: CatalogDatabase) async throws -> FixtureParityReport {
        var mismatches: [String] = []
        for source in sourceAssets {
            guard let rebuilt = try await rebuiltCatalog.assets.asset(id: source.id) else {
                mismatches.append("missing asset \(source.id.description)")
                continue
            }
            guard source.parentFolderID == rebuilt.parentFolderID,
                  source.filename == rebuilt.filename,
                  source.displayName == rebuilt.displayName,
                  source.width == rebuilt.width,
                  source.height == rebuilt.height,
                  source.createdAt == rebuilt.createdAt,
                  source.modifiedAt == rebuilt.modifiedAt,
                  source.importedAt == rebuilt.importedAt,
                  source.favorite == rebuilt.favorite,
                  source.rating == rebuilt.rating,
                  source.metadata == rebuilt.metadata else {
                mismatches.append("asset metadata mismatch \(source.id.description)")
                continue
            }
            let rebuiltBlobSHA256 = try await rebuiltCatalog.blobs.blobSHA256(for: source.id)
            if rebuiltBlobSHA256 != sourceBlobSHA256[source.id] {
                mismatches.append("blob association mismatch \(source.id.description)")
            }
        }
        return FixtureParityReport(mismatches: mismatches)
    }
}

public enum FixtureParityVerifierError: Error, Equatable, Sendable {
    case missingBlob(assetID: AssetID, sha256: String)
}

/// Portable, sidecar-only evidence captured from a deterministic fixture
/// library. It intentionally contains catalog relationships and checksums,
/// never original bytes and never a user-library path.
public struct FixtureLibraryManifest: Codable, Sendable {
    public static let formatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date
    public let folders: [Folder]
    public let blobs: [FixtureManifestBlob]
    public let assets: [FixtureManifestAsset]

    public init(exportedAt: Date, folders: [Folder], blobs: [FixtureManifestBlob], assets: [FixtureManifestAsset]) {
        self.formatVersion = Self.formatVersion
        self.exportedAt = exportedAt
        self.folders = folders
        self.blobs = blobs
        self.assets = assets
    }
}

public struct FixtureManifestBlob: Codable, Sendable {
    public let sha256: String
    public let byteSize: Int64
    public let mediaType: String
    public let originalExtension: String
    public let createdAt: Date

    init(digest: FileDigest, asset: Asset) {
        sha256 = digest.sha256
        byteSize = digest.byteSize
        mediaType = "image/jpeg"
        originalExtension = asset.filename.split(separator: ".").last.map(String.init) ?? "bin"
        createdAt = asset.importedAt
    }

    var blob: Blob {
        Blob(
            sha256: sha256,
            byteSize: byteSize,
            mediaType: mediaType,
            originalExtension: originalExtension,
            r2Key: "fixture-manifest/\(sha256)",
            uploadState: .verified,
            verificationETag: nil,
            verifiedAt: createdAt,
            createdAt: createdAt
        )
    }
}

public struct FixtureManifestAsset: Codable, Sendable {
    public let id: AssetID
    public let blobSHA256: String
    public let folderID: FolderID
    public let filename: String
    public let displayName: String
    public let storageKey: AssetStorageKey
    public let width: Int?
    public let height: Int?
    public let createdAt: Date
    public let modifiedAt: Date
    public let importedAt: Date
    public let favorite: Bool
    public let rating: AssetRating
    public let metadata: AssetMetadata

    init(asset: Asset, blobSHA256: String) {
        id = asset.id
        self.blobSHA256 = blobSHA256
        folderID = asset.parentFolderID
        filename = asset.filename
        displayName = asset.displayName
        storageKey = asset.storageKey
        width = asset.width
        height = asset.height
        createdAt = asset.createdAt
        modifiedAt = asset.modifiedAt
        importedAt = asset.importedAt
        favorite = asset.favorite
        rating = asset.rating
        metadata = asset.metadata
    }

    var remoteAsset: FixtureRemoteAsset {
        FixtureRemoteAsset(
            id: id,
            blobSHA256: blobSHA256,
            folderID: folderID,
            filename: filename,
            displayName: displayName,
            width: width,
            height: height,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            importedAt: importedAt,
            favorite: favorite,
            rating: rating,
            metadata: metadata
        )
    }

    func sourceAsset(fileSize: Int64) -> Asset {
        Asset(
            id: id,
            filename: filename,
            displayName: displayName,
            parentFolderID: folderID,
            storageKey: storageKey,
            fileSize: fileSize,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            importedAt: importedAt,
            updatedAt: importedAt,
            favorite: favorite,
            rating: rating,
            metadata: metadata
        )
    }
}

public struct FixtureRestoreDrillReport: Equatable, Sendable {
    public let manifestURL: URL
    public let rebuiltCatalogURL: URL
    public let parity: FixtureParityReport
    public let missingOriginalAssetIDs: [AssetID]
    public let checksumMismatchAssetIDs: [AssetID]

    public var isSuccessful: Bool {
        parity.isEquivalent && missingOriginalAssetIDs.isEmpty && checksumMismatchAssetIDs.isEmpty
    }
}

public enum FixtureLibraryManifestError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case missingOriginal(AssetID)
    case missingManifest(URL)
}

/// Exports and replays a manifest only after the existing fixture capability
/// has bound the operation to `Framebase Fixture Library.framebase`. Restore
/// always creates a new catalog beneath that fixture; it never opens, alters,
/// or deletes a real library or an original file.
public enum FixtureLibraryManifestService {
    public static func manifestURL(for authorization: FixtureMigrationAuthorization) -> URL {
        authorization.rootURL
            .appending(path: "Recovery", directoryHint: .isDirectory)
            .appending(path: "fixture-library-manifest.json", directoryHint: .notDirectory)
    }

    @discardableResult
    public static func export(
        authorization: FixtureMigrationAuthorization,
        catalog: CatalogDatabase,
        digestService: FileDigestService = FileDigestService()
    ) async throws -> URL {
        let allIDs = try await catalog.assets.orderedIDs(
            matching: AssetQuery(scope: .allAssets),
            sortedBy: .defaultSort
        )
        let trashIDs = try await catalog.assets.orderedIDs(
            matching: AssetQuery(scope: .trash),
            sortedBy: .defaultSort
        )
        let assets = try await catalog.assets.assets(ids: Set(allIDs + trashIDs))
            .sorted { $0.id.description < $1.id.description }
        let originalsURL = authorization.rootURL.appending(path: "Originals", directoryHint: .isDirectory)

        var blobs: [FixtureManifestBlob] = []
        var manifestAssets: [FixtureManifestAsset] = []
        for asset in assets {
            let originalURL = originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: originalURL.path) else {
                throw FixtureLibraryManifestError.missingOriginal(asset.id)
            }
            let digest = try await digestService.digest(at: originalURL)
            blobs.append(FixtureManifestBlob(digest: digest, asset: asset))
            manifestAssets.append(FixtureManifestAsset(asset: asset, blobSHA256: digest.sha256))
        }

        let folderSnapshot = try await catalog.folders.treeSnapshot()
        let manifest = FixtureLibraryManifest(
            exportedAt: Date(),
            folders: folderSnapshot.folders.filter { $0.systemKind == nil },
            blobs: blobs,
            assets: manifestAssets
        )
        let destinationURL = manifestURL(for: authorization)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    public static func restoreDrill(
        authorization: FixtureMigrationAuthorization,
        digestService: FileDigestService = FileDigestService()
    ) async throws -> FixtureRestoreDrillReport {
        let sourceManifestURL = manifestURL(for: authorization)
        guard FileManager.default.fileExists(atPath: sourceManifestURL.path) else {
            throw FixtureLibraryManifestError.missingManifest(sourceManifestURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(FixtureLibraryManifest.self, from: Data(contentsOf: sourceManifestURL))
        guard manifest.formatVersion == FixtureLibraryManifest.formatVersion else {
            throw FixtureLibraryManifestError.unsupportedFormatVersion(manifest.formatVersion)
        }

        let recoveryURL = authorization.rootURL
            .appending(path: "Recovery", directoryHint: .isDirectory)
            .appending(path: "RestoreDrill-\(UUID().uuidString)", directoryHint: .isDirectory)
        let rebuiltCatalogURL = recoveryURL
            .appending(path: "Catalog", directoryHint: .isDirectory)
            .appending(path: "catalog.sqlite", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: rebuiltCatalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let rebuiltCatalog = try await FixtureParityVerifier.rebuildCatalog(
            from: FixtureRemoteCatalogSnapshot(
                folders: manifest.folders,
                blobs: manifest.blobs.map(\.blob),
                assets: manifest.assets.map(\.remoteAsset)
            ),
            at: rebuiltCatalogURL
        )
        let sourceBlobSHA256 = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0.blobSHA256) })
        let blobSizeBySHA256 = Dictionary(uniqueKeysWithValues: manifest.blobs.map { ($0.sha256, $0.byteSize) })
        let sourceAssets = manifest.assets.map {
            $0.sourceAsset(fileSize: blobSizeBySHA256[$0.blobSHA256] ?? 0)
        }
        let parity = try await FixtureParityVerifier.compare(
            sourceAssets: sourceAssets,
            sourceBlobSHA256: sourceBlobSHA256,
            rebuiltCatalog: rebuiltCatalog
        )

        let originalsURL = authorization.rootURL.appending(path: "Originals", directoryHint: .isDirectory)
        var missingOriginalAssetIDs: [AssetID] = []
        var checksumMismatchAssetIDs: [AssetID] = []
        for asset in manifest.assets {
            let originalURL = originalsURL.appending(path: asset.storageKey.rawValue, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: originalURL.path) else {
                missingOriginalAssetIDs.append(asset.id)
                continue
            }
            let digest = try await digestService.digest(at: originalURL)
            let expectedSize = blobSizeBySHA256[asset.blobSHA256]
            if digest.sha256 != asset.blobSHA256 || digest.byteSize != expectedSize {
                checksumMismatchAssetIDs.append(asset.id)
            }
        }

        return FixtureRestoreDrillReport(
            manifestURL: sourceManifestURL,
            rebuiltCatalogURL: rebuiltCatalogURL,
            parity: parity,
            missingOriginalAssetIDs: missingOriginalAssetIDs.sorted { $0.description < $1.description },
            checksumMismatchAssetIDs: checksumMismatchAssetIDs.sorted { $0.description < $1.description }
        )
    }
}
