import FramebaseDomain
import Observation

enum NavigationTarget: Hashable, Sendable {
    case allAssets
    case inbox
    case favorites
    case folder(FolderID)
    case album(AlbumID)

    var title: String {
        switch self {
        case .allAssets: "All Assets"
        case .inbox: "Inbox"
        case .favorites: "Favorites"
        case .folder: "Folder"
        case .album: "Album"
        }
    }

    var assetScope: AssetScope {
        switch self {
        case .allAssets: .allAssets
        case .inbox: .inbox
        case .favorites: .favorites
        case let .folder(id): .folder(id)
        case let .album(id): .album(id)
        }
    }
}

@MainActor
@Observable
final class LibraryWindowModel {
    let container: AppContainer

    var navigationTarget: NavigationTarget = .allAssets {
        didSet {
            assetQuery = AssetQuery(scope: navigationTarget.assetScope)
            cancelQueryWork()
        }
    }
    var assetQuery = AssetQuery(scope: .allAssets)
    var assetSort = AssetSort.defaultSort
    var orderedVisibleAssetIDs: [AssetID] = []
    var selectedAssetIDs: Set<AssetID> = []
    var selectionAnchorID: AssetID?
    var keyboardFocusedAssetID: AssetID?
    var expandedFolderIDs: Set<FolderID> = []
    var isInspectorVisible = true
    var thumbnailSize: Double = 176
    var importRequestGeneration = 0
    var isImporting = false
    var statusMessage: String?

    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailPrefetchTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    deinit {
        observationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
    }

    func requestImport() {
        importRequestGeneration &+= 1
    }

    func selectAllVisibleAssets() {
        selectedAssetIDs = Set(orderedVisibleAssetIDs)
        selectionAnchorID = orderedVisibleAssetIDs.first
    }

    func clearSelection() {
        selectedAssetIDs.removeAll()
        selectionAnchorID = nil
        keyboardFocusedAssetID = nil
    }

    func cancelQueryWork() {
        observationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
        observationTask = nil
        thumbnailPrefetchTask = nil
    }
}
