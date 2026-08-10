import FramebaseCatalog
import FramebaseAPIClient
import FramebaseDomain
import FramebaseMedia
import FramebaseSync
import Foundation
import Observation

@MainActor
@Observable
final class AppContainer {
    enum LibraryState: Equatable {
        case notConfigured
        case opening
        case ready(CatalogID)
        case failed(String)
    }

    private(set) var libraryState: LibraryState = .notConfigured
    private(set) var libraryRootURL: URL?
    private(set) var cloudStatus = CloudLibraryStatus()
    private(set) var cloudConflicts: [SyncConflict] = []
    private(set) var isPreparingCloudMigration = false

    @ObservationIgnored private let libraryCoordinator = LibraryPackageCoordinator()
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var didAttemptLibraryRestore = false
    @ObservationIgnored private(set) var catalogDatabase: CatalogDatabase?
    @ObservationIgnored private(set) var assetRepository: (any AssetRepository)?
    @ObservationIgnored private(set) var folderRepository: (any FolderRepository)?
    @ObservationIgnored private(set) var albumRepository: (any AlbumRepository)?
    @ObservationIgnored private(set) var tagRepository: (any TagRepository)?
    @ObservationIgnored private(set) var savedSearchRepository: (any SavedSearchRepository)?
    @ObservationIgnored private(set) var assetBlobStore: (any AssetBlobStore)?
    @ObservationIgnored private(set) var importCoordinator: (any ImportCoordinator)?
    @ObservationIgnored private(set) var thumbnailProvider: (any ThumbnailProvider)?
    @ObservationIgnored private(set) var cloudSync: FramebaseSync?

    let catalogSchemaVersion = FramebaseCatalogFoundation.currentSchemaVersion
    let thumbnailCacheFormatVersion = FramebaseMediaFoundation.thumbnailCacheFormatVersion

    private static let libraryRootPreferenceKey = "framebase.libraryRootPath"

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    var canBrowseLibrary: Bool {
        if case .ready = libraryState {
            return true
        }
        return false
    }

    var cloudBackingIsActive: Bool {
        cloudStatus.mode == .cloudBacked || cloudStatus.mode == .syncing || cloudStatus.mode == .preparingMigration
    }

    func markLibraryOpening() {
        libraryState = .opening
    }

    func markLibraryReady(catalogID: CatalogID) {
        libraryState = .ready(catalogID)
    }

    func markLibraryFailed(message: String) {
        libraryState = .failed(message)
    }

    func restoreLibraryIfAvailable() async {
        guard !didAttemptLibraryRestore else {
            return
        }
        didAttemptLibraryRestore = true

#if DEBUG
        if let testPath = ProcessInfo.processInfo.environment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] {
            libraryState = .opening
            do {
                let layout = try await libraryCoordinator.createLibrary(
                    at: URL(fileURLWithPath: testPath, isDirectory: true)
                )
                try await activateLibrary(layout, persistSelection: false)
            } catch {
                libraryState = .failed(error.localizedDescription)
            }
            return
        }
#endif

        guard let persistedPath = preferences.string(forKey: Self.libraryRootPreferenceKey) else {
            return
        }

        await openLibrary(at: URL(fileURLWithPath: persistedPath, isDirectory: true))
    }

    func createDefaultLibrary() async {
        libraryState = .opening

        do {
            let rootURL = try LibraryPackageLayout.defaultRootURL()
            let layout = try await libraryCoordinator.createLibrary(at: rootURL)
            try await activateLibrary(layout)
        } catch {
            libraryState = .failed(error.localizedDescription)
        }
    }

    func openLibrary(at rootURL: URL) async {
        libraryState = .opening

        do {
            let layout = try await libraryCoordinator.openLibrary(at: rootURL)
            try await activateLibrary(layout)
        } catch {
            libraryState = .failed(error.localizedDescription)
        }
    }

    func clearDerivedCache() async throws {
        try await thumbnailProvider?.clearDerivedCache()
    }

    func updateThumbnailDiskLimit(gigabytes: Double) throws {
        guard let blobStore = assetBlobStore else { return }
        let boundedGigabytes = min(max(gigabytes, 1), 20)
        thumbnailProvider = try ImageIOThumbnailProvider(
            blobStore: blobStore,
            cacheDirectoryURL: try Self.thumbnailCacheDirectoryURL(),
            diskCacheByteLimit: Int64(boundedGigabytes * 1_024 * 1_024 * 1_024)
        )
    }

    /// Prepares only a local migration manifest and immutable SHA-256 records.
    /// The one-time pairing credential is used in memory for enrollment and is
    /// never written to this app, UserDefaults, or the library package.
    func prepareCloudMigration(pairingCredential: String) async throws {
        guard let catalogDatabase, let assetBlobStore else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard !pairingCredential.isEmpty else {
            throw CloudPreparationError.pairingCredentialRequired
        }
        isPreparingCloudMigration = true
        defer { isPreparingCloudMigration = false }

        let catalogID = catalogDatabase.catalogID.description
        let keyStore = SecureDeviceKeyStore(applicationTag: "com.vincentlaroche.framebase.device.\(catalogID)")
        let sessionStore = KeychainDeviceSessionStore(
            service: "com.vincentlaroche.framebase.api",
            account: catalogID
        )
        let api = FramebaseAPIClient(
            configuration: FramebaseAPIConfiguration(baseURL: Self.developmentAPIURL),
            sessionStore: sessionStore
        )
        let deviceName = Host.current().localizedName ?? "Framebase Mac"
        let enrollment = DeviceEnrollmentRequest(
            deviceID: catalogID,
            deviceName: deviceName,
            publicKey: try keyStore.publicKeyBase64URL(),
            scopes: [
                "library.read",
                "assets.import",
                "assets.metadata.write",
                "assets.organize",
                "originals.download",
                "trash.write",
                "library.preferences.write"
            ]
        )
        _ = try await api.enroll(request: enrollment, pairingCredential: pairingCredential, signer: keyStore)
        let sync = FramebaseSync(catalog: catalogDatabase, blobStore: assetBlobStore, api: api)
        _ = try await sync.prepareMigrationManifest()
        _ = try await sync.hashPendingOriginals()
        cloudSync = sync
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    /// Performs the explicit next migration step. It never removes a managed
    /// local original and remains restartable from the catalog's cloud tables.
    func uploadPreparedCloudBlobs() async throws {
        guard let cloudSync, let catalogDatabase else { throw CloudPreparationError.migrationNotPrepared }
        try await cloudSync.uploadVerifiedLocalBlobs()
        try await cloudSync.publishInitialCatalog()
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    func refreshCloudStatus() async {
        guard let catalogDatabase else { return }
        cloudStatus = (try? await catalogDatabase.cloud.status()) ?? CloudLibraryStatus()
        cloudConflicts = (try? await catalogDatabase.cloud.unresolvedConflicts()) ?? []
    }

    /// Records an already-committed local asset edit for cloud synchronization.
    /// The outbox is durable before networking starts, so going offline here
    /// cannot lose the local change or mutate managed originals.
    func queueCloudAssetMutation(_ mutation: CloudAssetMutation, for assetIDs: Set<AssetID>) async throws {
        guard cloudStatus.mode == .cloudBacked || cloudStatus.mode == .syncing,
              let cloudSync, let catalogDatabase else { return }
        try await cloudSync.enqueueAssetMutation(mutation, for: assetIDs)
        try await cloudSync.sendQueuedChanges()
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    func queueCloudFolderMutation(_ mutation: CloudFolderMutation) async throws {
        guard cloudStatus.mode == .cloudBacked || cloudStatus.mode == .syncing,
              let cloudSync, let catalogDatabase else { return }
        try await cloudSync.enqueueFolderMutation(mutation)
        try await cloudSync.sendQueuedChanges()
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    func queueCloudTagMutation(_ mutation: CloudTagMutation) async throws {
        guard cloudBackingIsActive, let cloudSync, let catalogDatabase else { return }
        try await cloudSync.enqueueTagMutation(mutation)
        try await cloudSync.sendQueuedChanges()
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    func queueCloudSavedSearchMutation(_ mutation: CloudSavedSearchMutation) async throws {
        guard cloudBackingIsActive, let cloudSync, let catalogDatabase else { return }
        try await cloudSync.enqueueSavedSearchMutation(mutation)
        try await cloudSync.sendQueuedChanges()
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    func queueCloudAlbumMutation(_ mutation: CloudAlbumMutation) async throws {
        guard cloudBackingIsActive, let cloudSync, let catalogDatabase else { return }
        try await cloudSync.enqueueAlbumMutation(mutation)
        try await cloudSync.sendQueuedChanges()
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    func queueCloudExportReceipt(_ receipt: AssetExportReceipt) async throws {
        guard cloudBackingIsActive, let cloudSync, let catalogDatabase else { return }
        try await cloudSync.enqueueExportReceiptMutation(.record(receipt))
        try await cloudSync.sendQueuedChanges()
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    func synchronizeCloudImportedAssets(_ assetIDs: Set<AssetID>) async throws {
        guard cloudStatus.mode == .cloudBacked || cloudStatus.mode == .syncing,
              let cloudSync, let catalogDatabase else { return }
        try await cloudSync.synchronizeImportedAssets(assetIDs)
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    func resolveCloudConflict(_ conflict: SyncConflict, as resolution: SyncConflictResolutionState) async throws {
        guard let cloudSync, let catalogDatabase else { throw CloudPreparationError.migrationNotPrepared }
        try await cloudSync.resolveConflict(conflict, as: resolution)
        cloudStatus = try await catalogDatabase.cloud.status()
        cloudConflicts = try await catalogDatabase.cloud.unresolvedConflicts()
    }

    private func activateLibrary(_ layout: LibraryPackageLayout, persistSelection: Bool = true) async throws {
        let catalog = try CatalogDatabase(catalogURL: layout.catalogDatabaseURL)
        let blobStore = try ManagedAssetBlobStore(
            originalsDirectoryURL: layout.originalsDirectoryURL,
            stagingDirectoryURL: layout.stagingDirectoryURL
        )
        let recovery = try await blobStore.recoverStaging()
        guard recovery.failedURLs.isEmpty else {
            throw LibraryPackageError.stagingRecoveryFailed(recovery.failedURLs.count)
        }

        catalogDatabase = catalog
        assetRepository = catalog.assets
        folderRepository = catalog.folders
        albumRepository = catalog.albums
        tagRepository = catalog.tags
        savedSearchRepository = catalog.savedSearches
        assetBlobStore = blobStore
        importCoordinator = ManagedImportCoordinator(
            blobStore: blobStore,
            metadataExtractor: ImageIOMetadataExtractor(),
            insertIntoCatalog: { assets in
                try await catalog.insertAssets(assets)
            }
        )
        let sessionStore = KeychainDeviceSessionStore(
            service: "com.vincentlaroche.framebase.api",
            account: catalog.catalogID.description
        )
        cloudSync = FramebaseSync(
            catalog: catalog,
            blobStore: blobStore,
            api: FramebaseAPIClient(
                configuration: FramebaseAPIConfiguration(baseURL: Self.developmentAPIURL),
                sessionStore: sessionStore
            )
        )
        cloudStatus = (try? await catalog.cloud.status()) ?? CloudLibraryStatus()
        cloudConflicts = (try? await catalog.cloud.unresolvedConflicts()) ?? []
        thumbnailProvider = try ImageIOThumbnailProvider(
            blobStore: blobStore,
            cacheDirectoryURL: try Self.thumbnailCacheDirectoryURL()
        )
        libraryRootURL = layout.rootURL
        if persistSelection {
            preferences.set(layout.rootURL.path, forKey: Self.libraryRootPreferenceKey)
        }
        libraryState = .ready(catalog.catalogID)
    }

    private static func thumbnailCacheDirectoryURL() throws -> URL {
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return cachesURL
            .appendingPathComponent("com.vincentlaroche.framebase", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private static let developmentAPIURL = URL(string: "https://framebase-api-dev.notionsync.workers.dev")!
}

enum CloudPreparationError: LocalizedError {
    case pairingCredentialRequired
    case migrationNotPrepared

    var errorDescription: String? {
        switch self {
        case .pairingCredentialRequired: "A one-time pairing credential is required to prepare cloud backing."
        case .migrationNotPrepared: "Prepare a cloud migration manifest before uploading originals."
        }
    }
}
