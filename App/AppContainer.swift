import FramebaseAPIClient
import FramebaseCatalog
import FramebaseCatalogSync
import FramebaseDomain
import FramebaseMedia
import FramebaseSync
import Foundation
import Observation

enum AppContainerError: Error, LocalizedError {
    case invalidEnrollmentResponse

    var errorDescription: String? {
        switch self {
        case .invalidEnrollmentResponse:
            "The server's enrollment response could not be understood."
        }
    }
}

@MainActor
@Observable
final class AppContainer {
    enum LibraryState: Equatable {
        case notConfigured
        case opening
        case ready(CatalogID)
        case failed(String)
    }

    /// Dev-phase device enrollment against `framebase-api-dev`. Independent of
    /// `LibraryState` — device identity isn't library data, so this is
    /// available whether or not a library is open.
    enum EnrollmentStatus: Equatable {
        case notEnrolled
        case enrolled(deviceId: String, expiresAt: Date)
        case expired(deviceId: String)
    }

    /// `framebase-api-dev`, the Cloudflare dev Worker deployed for Phase 2.
    /// Development-only: no production API exists yet.
    static let cloudDevBaseURL = URL(string: "https://framebase-api-dev.notionsync.workers.dev")!

    private(set) var libraryState: LibraryState = .notConfigured
    private(set) var libraryRootURL: URL?
    private(set) var enrollmentStatus: EnrollmentStatus = .notEnrolled

    @ObservationIgnored private let cloudCredentialStore: any DeviceCredentialStore
    @ObservationIgnored private let apiClient: any APIClientProtocol
    @ObservationIgnored private static let cloudDeviceIDPreferenceKey = "framebase.cloudDeviceId"

    @ObservationIgnored private let libraryCoordinator = LibraryPackageCoordinator()
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var didAttemptLibraryRestore = false
    @ObservationIgnored private(set) var catalogDatabase: CatalogDatabase?
    @ObservationIgnored private(set) var assetRepository: (any AssetRepository)?
    @ObservationIgnored private(set) var folderRepository: (any FolderRepository)?
    @ObservationIgnored private(set) var albumRepository: (any AlbumRepository)?
    @ObservationIgnored private(set) var assetBlobStore: (any AssetBlobStore)?
    @ObservationIgnored private(set) var importCoordinator: (any ImportCoordinator)?
    @ObservationIgnored private(set) var thumbnailProvider: (any ThumbnailProvider)?
    @ObservationIgnored private(set) var librarySyncCoordinator: LibrarySyncCoordinator?

    let catalogSchemaVersion = FramebaseCatalogFoundation.initialSchemaVersion
    let thumbnailCacheFormatVersion = FramebaseMediaFoundation.thumbnailCacheFormatVersion

    private static let libraryRootPreferenceKey = "framebase.libraryRootPath"

    /// Defaults to false and nothing shipped in this app writes it yet —
    /// deliberately. Real catalog sync (`FramebaseCatalogSync`) is built and
    /// proven against fixtures, but turning it on for a real library is a
    /// separate, explicit decision, not a side effect of enrolling a device
    /// to test the Cloud (Dev) Settings tab.
    private static let cloudSyncEnabledPreferenceKey = "framebase.cloudSyncEnabled"

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let credentialStore = KeychainDeviceCredentialStore()
        self.cloudCredentialStore = credentialStore
        self.apiClient = FramebaseAPIClient(baseURL: Self.cloudDevBaseURL, credentialStore: credentialStore)
    }

    var canBrowseLibrary: Bool {
        if case .ready = libraryState {
            return true
        }
        return false
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

    // MARK: - Cloud (dev) device enrollment
    //
    // Independent of library state by design. Enrolling only registers this
    // Mac against `framebase-api-dev` and stores a session JWT in Keychain —
    // it never touches catalog data, and nothing here starts a `SyncEngine`
    // against the real library. Real catalog sync is out of scope until
    // Phase 2's "fixture assets only, no personal photos" boundary is
    // explicitly lifted.

    func refreshEnrollmentStatus() async {
        guard let credential = try? await cloudCredentialStore.currentCredential() else {
            enrollmentStatus = .notEnrolled
            return
        }
        enrollmentStatus = credential.isExpired()
            ? .expired(deviceId: credential.deviceId)
            : .enrolled(deviceId: credential.deviceId, expiresAt: credential.expiresAt)
    }

    func enrollDevice(enrollmentSecret: String, deviceName: String) async throws {
        let deviceID = persistedOrNewCloudDeviceID()
        let response = try await apiClient.enroll(
            enrollmentSecret: enrollmentSecret,
            request: EnrollRequest(
                deviceId: deviceID,
                deviceName: deviceName,
                publicKey: "unused-phase-2-shared-secret-gate"
            )
        )
        guard let expiresAt = ISO8601Coding.parse(response.expiresAt) else {
            throw AppContainerError.invalidEnrollmentResponse
        }
        try await cloudCredentialStore.store(StoredDeviceCredential(
            deviceId: response.deviceId,
            token: response.token,
            expiresAt: expiresAt
        ))
        await refreshEnrollmentStatus()
    }

    func forgetDevice() async throws {
        try await cloudCredentialStore.clear()
        await refreshEnrollmentStatus()
    }

    func checkCloudHealth() async throws -> HealthResponse {
        try await apiClient.health()
    }

    private func persistedOrNewCloudDeviceID() -> String {
        if let existing = preferences.string(forKey: Self.cloudDeviceIDPreferenceKey) {
            return existing
        }
        let newID = UUID().uuidString
        preferences.set(newID, forKey: Self.cloudDeviceIDPreferenceKey)
        return newID
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

    private func activateLibrary(_ layout: LibraryPackageLayout, persistSelection: Bool = true) async throws {
        await librarySyncCoordinator?.stop()
        librarySyncCoordinator = nil

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
        albumRepository = catalog.albums
        assetBlobStore = blobStore
        importCoordinator = ManagedImportCoordinator(
            blobStore: blobStore,
            metadataExtractor: ImageIOMetadataExtractor(),
            insertIntoCatalog: { assets in
                try await catalog.insertAssets(assets)
            }
        )
        thumbnailProvider = try ImageIOThumbnailProvider(
            blobStore: blobStore,
            cacheDirectoryURL: try Self.thumbnailCacheDirectoryURL()
        )
        libraryRootURL = layout.rootURL
        if persistSelection {
            preferences.set(layout.rootURL.path, forKey: Self.libraryRootPreferenceKey)
        }

        try await activateCatalogSync(for: catalog, layout: layout)

        libraryState = .ready(catalog.catalogID)
    }

    /// Wires real catalog sync only when both are true: `cloudSyncEnabled`
    /// (nothing shipped sets it yet) and a live, unexpired device
    /// enrollment. Otherwise `assetRepository`/`folderRepository` stay the
    /// plain, non-syncing repositories exactly as before this existed.
    private func activateCatalogSync(for catalog: CatalogDatabase, layout: LibraryPackageLayout) async throws {
        guard preferences.bool(forKey: Self.cloudSyncEnabledPreferenceKey),
              let credential = try? await cloudCredentialStore.currentCredential(),
              !credential.isExpired() else {
            assetRepository = catalog.assets
            folderRepository = catalog.folders
            return
        }

        let syncState = try SyncStateStore(databaseURL: layout.syncDatabaseURL)
        let recorder = CatalogOutboxRecorder(outbox: syncState, actorID: credential.deviceId)

        assetRepository = SyncingAssetRepository(wrapping: catalog.assets, recorder: recorder)
        folderRepository = SyncingFolderRepository(wrapping: catalog.folders, recorder: recorder)

        // The applier uses the raw repositories, never the syncing
        // decorators above — applying a pulled change through the decorator
        // would re-record it into the outbox and push it straight back.
        let applier = CatalogChangeApplier(folders: catalog.folders, assets: catalog.assets, ownActorID: credential.deviceId)
        let engine = DefaultSyncEngine(
            apiClient: apiClient,
            outbox: syncState,
            cursorStore: syncState,
            changeApplier: applier
        )
        let coordinator = LibrarySyncCoordinator(engine: engine)
        await coordinator.start()
        librarySyncCoordinator = coordinator
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
}
