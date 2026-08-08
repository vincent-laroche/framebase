import FramebaseCatalog
import FramebaseDomain
import FramebaseMedia
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

    @ObservationIgnored private let libraryCoordinator = LibraryPackageCoordinator()
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var didAttemptLibraryRestore = false
    @ObservationIgnored private(set) var catalogDatabase: CatalogDatabase?
    @ObservationIgnored private(set) var assetRepository: (any AssetRepository)?
    @ObservationIgnored private(set) var folderRepository: (any FolderRepository)?
    @ObservationIgnored private(set) var albumRepository: (any AlbumRepository)?
    @ObservationIgnored private(set) var assetBlobStore: (any AssetBlobStore)?

    let catalogSchemaVersion = FramebaseCatalogFoundation.initialSchemaVersion
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
        assetBlobStore = blobStore
        libraryRootURL = layout.rootURL
        if persistSelection {
            preferences.set(layout.rootURL.path, forKey: Self.libraryRootPreferenceKey)
        }
        libraryState = .ready(catalog.catalogID)
    }
}
