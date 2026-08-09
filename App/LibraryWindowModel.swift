import AppKit
import FramebaseDomain
import FramebaseMedia
import Foundation
import Observation

struct FolderDeletionPrompt: Identifiable, Sendable {
    let folderID: FolderID
    let folderName: String
    let folderCount: Int
    let assetCount: Int

    var id: FolderID { folderID }
}

private struct LibraryHistoryEntry: Sendable {
    let actionName: String
    let action: LibraryHistoryAction
}

private enum LibraryHistoryAction: Sendable {
    case renameFolder(FolderID, to: FolderName)
    case reparentFolder(FolderID, to: FolderID?)
    case deleteFolder(FolderID)
    case restoreFolder(FolderDeletionReceipt)
    case renameAlbum(AlbumID, to: String)
    case reorderAlbums([AlbumID])
    case deleteAlbum(AlbumID)
    case restoreAlbum(AlbumDeletionReceipt)
    case renameTag(TagID, to: String)
    case deleteTag(TagID)
    case restoreTag(TagDeletionReceipt)
    case renameAsset(AssetID, to: String)
    case restoreAssetLocations(AssetMoveReceipt)
    case restoreTrash(TrashReceipt)
    case moveToTrash(Set<AssetID>)
}

private enum LibraryHistoryError: LocalizedError {
    case folderUnavailable
    case albumUnavailable
    case tagUnavailable

    var errorDescription: String? {
        switch self {
        case .folderUnavailable: "The folder is no longer available for that history action."
        case .albumUnavailable: "The album is no longer available for that history action."
        case .tagUnavailable: "The tag is no longer available for that history action."
        }
    }
}

enum AssetThumbnailState: Sendable {
    case loading
    case ready(ThumbnailPayload)
    case missing
    case corrupt
}

enum NavigationTarget: Hashable, Sendable {
    case allAssets
    case inbox
    case favorites
    case folder(FolderID)
    case album(AlbumID)
    case tag(TagID)
    case savedSearch(SavedSearchID)
    case smartCollection(SmartCollectionID)
    case trash

    var title: String {
        switch self {
        case .allAssets: "All Assets"
        case .inbox: "Inbox"
        case .favorites: "Favorites"
        case .folder: "Folder"
        case .album: "Album"
        case .tag: "Tag"
        case .savedSearch: "Saved Search"
        case .smartCollection: "Smart Collection"
        case .trash: "Trash"
        }
    }

    var assetScope: AssetScope {
        switch self {
        case .allAssets: .allAssets
        case .inbox: .inbox
        case .favorites: .favorites
        case let .folder(id): .folder(id)
        case let .album(id): .album(id)
        case let .tag(id): .tag(id)
        case .savedSearch: .allAssets
        case .smartCollection: .allAssets
        case .trash: .trash
        }
    }
}

@MainActor
@Observable
final class LibraryWindowModel {
    let container: AppContainer

    var navigationTarget: NavigationTarget = .allAssets {
        didSet {
            assetQuery = queryForNavigationTarget()
            restartAssetObservation()
        }
    }
    var assetQuery = AssetQuery(scope: .allAssets)
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            var query = queryForNavigationTarget()
            query.criteria.text = AssetSearchCriteria(text: searchText).text
            assetQuery = query
            restartAssetObservation()
        }
    }
    var assetSort = AssetSort.defaultSort {
        didSet { restartAssetObservation() }
    }
    var browserPresentation: AssetBrowserPresentation = .grid
    var orderedVisibleAssetIDs: [AssetID] = []
    var assetGridRecords: [AssetGridRecord] = []
    var thumbnailStates: [AssetID: AssetThumbnailState] = [:]
    var selectedAssetIDs: Set<AssetID> = [] {
        didSet {
            guard selectedAssetIDs != oldValue else { return }
            scheduleInspectorRefresh()
        }
    }
    var selectedAssets: [Asset] = []
    var inspectorSelectionIsLimited = false
    var inspectorPreviewState: AssetThumbnailState?
    var selectionAnchorID: AssetID?
    var keyboardFocusedAssetID: AssetID?
    var expandedFolderIDs: Set<FolderID> = []
    var isSidebarKeyboardFocused = false
    var sidebarFocusRequestGeneration = 0
    var folderTreeSnapshot: FolderTreeSnapshot?
    var albums: [Album] = []
    var tags: [Tag] = []
    var savedSearches: [SavedSearch] = []
    var smartCollections: [SmartCollection] = []
    var trashEntriesByAssetID: [AssetID: TrashEntry] = [:]
    var duplicateCandidates: [DuplicateCandidate] = []
    var pendingFolderDeletion: FolderDeletionPrompt?
    var isInspectorVisible = true
    var thumbnailSize: Double = 176 {
        didSet {
            guard thumbnailSize != oldValue else { return }
            cancelThumbnailWork(clearStates: true)
        }
    }
    var importRequestGeneration = 0
    var isImporting = false
    var importProgress: ImportProgress?
    var statusMessage: String?

    private var undoHistory: [LibraryHistoryEntry] = []
    private var redoHistory: [LibraryHistoryEntry] = []
    private var isApplyingHistory = false

    var canUndoAction: Bool { !undoHistory.isEmpty && !isApplyingHistory }
    var canRedoAction: Bool { !redoHistory.isEmpty && !isApplyingHistory }
    var undoActionName: String { undoHistory.last.map { "Undo \($0.actionName)" } ?? "Undo" }
    var redoActionName: String { redoHistory.last.map { "Redo \($0.actionName)" } ?? "Redo" }
    var moveDestinationFolders: [Folder] {
        folderTreeSnapshot?.folders.sorted {
            $0.name.rawValue.localizedStandardCompare($1.name.rawValue) == .orderedAscending
        } ?? []
    }

    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTasks: [AssetID: (ThumbnailRequestID, Task<Void, Never>)] = [:]
    @ObservationIgnored private var folderObservationTask: Task<Void, Never>?
    @ObservationIgnored private var albumObservationTask: Task<Void, Never>?
    @ObservationIgnored private var tagObservationTask: Task<Void, Never>?
    @ObservationIgnored private var savedSearchObservationTask: Task<Void, Never>?
    @ObservationIgnored private var smartCollectionObservationTask: Task<Void, Never>?
    @ObservationIgnored private var inspectorTask: Task<Void, Never>?
    @ObservationIgnored private var inspectorPreviewTask: Task<Void, Never>?
    @ObservationIgnored private var inspectorPreviewRequestID: ThumbnailRequestID?

    init(container: AppContainer) {
        self.container = container
    }

    deinit {
        observationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
        for (_, entry) in thumbnailTasks { entry.1.cancel() }
        folderObservationTask?.cancel()
        albumObservationTask?.cancel()
        tagObservationTask?.cancel()
        savedSearchObservationTask?.cancel()
        smartCollectionObservationTask?.cancel()
        inspectorTask?.cancel()
        inspectorPreviewTask?.cancel()
    }

    func requestImport() {
        importRequestGeneration &+= 1
    }

    func importAssets(from sourceURLs: [URL]) async {
        guard !sourceURLs.isEmpty,
              !isImporting,
              let coordinator = container.importCoordinator,
              let destinationFolderID = importDestinationFolderID else {
            return
        }

        isImporting = true
        importProgress = ImportProgress(completedCount: 0, totalCount: sourceURLs.count, currentFilename: nil)
        defer {
            isImporting = false
            importProgress = nil
        }

        do {
            let result = try await coordinator.importAssets(
                ImportRequest(sourceURLs: sourceURLs, destinationFolderID: destinationFolderID)
            ) { [weak self] progress in
                await self?.applyImportProgress(progress)
            }

            if result.cancelled {
                statusMessage = "Import cancelled. No new assets were added."
            } else if !result.failures.isEmpty {
                let importedCount = result.importedAssetIDs.count
                let failureCount = result.failures.count
                let firstReason = result.failures.first?.reason ?? "Unknown error"
                statusMessage = "Imported \(importedCount) image(s). \(failureCount) file(s) were skipped. \(firstReason)"
            }
            try await refreshVisibleAssetIDs()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func cancelImport() async {
        await container.importCoordinator?.cancelCurrentImport()
    }

    func undoLastAction() async {
        guard !isApplyingHistory, let entry = undoHistory.popLast() else { return }
        isApplyingHistory = true
        defer { isApplyingHistory = false }
        do {
            let inverse = try await performHistoryAction(entry.action)
            redoHistory.append(LibraryHistoryEntry(actionName: entry.actionName, action: inverse))
        } catch {
            undoHistory.append(entry)
            statusMessage = error.localizedDescription
        }
    }

    func redoLastAction() async {
        guard !isApplyingHistory, let entry = redoHistory.popLast() else { return }
        isApplyingHistory = true
        defer { isApplyingHistory = false }
        do {
            let inverse = try await performHistoryAction(entry.action)
            undoHistory.append(LibraryHistoryEntry(actionName: entry.actionName, action: inverse))
        } catch {
            redoHistory.append(entry)
            statusMessage = error.localizedDescription
        }
    }

    /// `NavigationTarget` is a plain identifier, so it can only name the
    /// library-wide destinations. Folder and album names live in the observed
    /// snapshots, which is why the resolved title belongs here.
    var navigationTitle: String {
        switch navigationTarget {
        case let .folder(folderID):
            folderTreeSnapshot?
                .folders
                .first { $0.id == folderID }?
                .name
                .description ?? navigationTarget.title
        case let .album(albumID):
            albums.first { $0.id == albumID }?.name ?? navigationTarget.title
        case let .tag(tagID):
            tags.first { $0.id == tagID }?.name ?? navigationTarget.title
        case let .savedSearch(savedSearchID):
            savedSearches.first { $0.id == savedSearchID }?.name ?? navigationTarget.title
        case let .smartCollection(smartCollectionID):
            smartCollections.first { $0.id == smartCollectionID }?.name ?? navigationTarget.title
        case .allAssets, .inbox, .favorites:
            navigationTarget.title
        case .trash:
            navigationTarget.title
        }
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
        observationTask = nil
        cancelThumbnailWork(clearStates: true)
    }

    func requestThumbnail(for record: AssetGridRecord, displayScale: Double) {
        guard thumbnailStates[record.id] == nil,
              thumbnailTasks[record.id] == nil,
              let provider = container.thumbnailProvider else { return }

        let request = ThumbnailRequest(
            storageKey: record.storageKey,
            fingerprint: AssetFingerprint(
                assetID: record.id,
                fileSize: record.fileSize,
                modifiedAtMilliseconds: Int64(record.modifiedAt.timeIntervalSince1970 * 1_000)
            ),
            target: ThumbnailTarget(
                width: max(1, Int(thumbnailSize.rounded())),
                height: max(1, Int(thumbnailSize.rounded())),
                displayScale: max(1, displayScale)
            )
        )
        // `requestThumbnail` is driven from `willDisplay` and prefetch, which
        // AppKit calls inside the hosting view's layout pass. Publishing an
        // observed change there re-entrantly asks SwiftUI to update during
        // layout, and AppKit raises from `_postWindowNeedsUpdateConstraints`.
        // `thumbnailTasks` is not observed, so it can carry the de-duplication
        // synchronously while the visible state lands on a later turn.
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            thumbnailStates[record.id] = .loading
            do {
                let payload = try await provider.thumbnail(for: request)
                guard !Task.isCancelled else { return }
                thumbnailStates[record.id] = .ready(payload)
            } catch is CancellationError {
                return
            } catch {
                let originalAvailable = await container.assetBlobStore?.validate(record.storageKey) ?? false
                thumbnailStates[record.id] = originalAvailable ? .corrupt : .missing
            }
            thumbnailTasks.removeValue(forKey: record.id)
        }
        thumbnailTasks[record.id] = (request.id, task)
    }

    func cancelThumbnail(for assetID: AssetID) {
        guard let entry = thumbnailTasks.removeValue(forKey: assetID) else { return }
        entry.1.cancel()
        Task { await container.thumbnailProvider?.cancel(requestID: entry.0) }
        if case .loading = thumbnailStates[assetID] {
            thumbnailStates.removeValue(forKey: assetID)
        }
    }

    func loadNextAssetPageIfNeeded(near index: Int) {
        guard index >= max(0, assetGridRecords.count - 40),
              assetGridRecords.count < orderedVisibleAssetIDs.count,
              thumbnailPrefetchTask == nil,
              let repository = container.assetRepository else { return }

        let query = assetQuery
        let sort = assetSort
        let offset = assetGridRecords.count
        thumbnailPrefetchTask = Task { [weak self] in
            defer { self?.thumbnailPrefetchTask = nil }
            do {
                let page = try await repository.page(
                    matching: query,
                    sortedBy: sort,
                    offset: offset,
                    limit: 200
                )
                guard let self, !Task.isCancelled,
                      query == assetQuery, sort == assetSort,
                      assetGridRecords.count == offset else { return }
                assetGridRecords.append(contentsOf: page.records)
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    func canMoveAssets(_ assetIDs: Set<AssetID>, to folderID: FolderID) -> Bool {
        guard !assetIDs.isEmpty,
              folderTreeSnapshot?.folders.contains(where: { $0.id == folderID }) == true else {
            return false
        }
        switch navigationTarget {
        case let .folder(currentFolderID): return currentFolderID != folderID
        case .inbox: return folderTreeSnapshot?.inboxID != folderID
        default: return true
        }
    }

    func moveAssets(_ assetIDs: Set<AssetID>, to folderID: FolderID) async {
        guard canMoveAssets(assetIDs, to: folderID),
              let repository = container.assetRepository else { return }
        do {
            let receipt = try await repository.moveAssetsWithReceipt(assetIDs, to: folderID)
            recordAction(named: "Move Assets", undo: .restoreAssetLocations(receipt))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameSelectedAsset(to displayName: String) async {
        guard selectedAssetIDs.count == 1,
              let assetID = selectedAssetIDs.first,
              let repository = container.assetRepository else { return }
        do {
            guard let asset = try await repository.asset(id: assetID) else { return }
            try await repository.updateDisplayName(displayName, for: assetID)
            recordAction(named: "Rename Asset", undo: .renameAsset(assetID, to: asset.displayName))
            await refreshInspectorNow()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func revealSelectedOriginals() {
        guard !selectedAssetIDs.isEmpty,
              let libraryRootURL = container.libraryRootURL,
              !selectedAssets.isEmpty else { return }
        let originalsURL = libraryRootURL.appendingPathComponent("Originals", isDirectory: true)
        let fileURLs = selectedAssets
            .map { originalsURL.appendingPathComponent($0.storageKey.rawValue, isDirectory: false) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !fileURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
    }

    func moveSelectedAssetsToTrash() async {
        guard !selectedAssetIDs.isEmpty, let repository = container.assetRepository else { return }
        do {
            let receipt = try await repository.moveToTrash(selectedAssetIDs, retentionDays: 30)
            selectedAssetIDs = []
            recordAction(named: "Move to Trash", undo: .restoreTrash(receipt))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restoreSelectedAssetsFromTrash() async {
        guard !selectedAssetIDs.isEmpty, let repository = container.assetRepository else { return }
        do {
            let receipt = try await repository.restoreFromTrash(selectedAssetIDs)
            selectedAssetIDs = []
            recordAction(named: "Restore from Trash", undo: .moveToTrash(Set(receipt.entries.map(\.assetID))))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportSelectedAssets(to destinationDirectoryURL: URL) async {
        guard !selectedAssetIDs.isEmpty,
              let repository = container.assetRepository,
              let libraryRootURL = container.libraryRootURL else { return }
        do {
            let assets = try await repository.assets(ids: selectedAssetIDs)
            let originalsURL = libraryRootURL.appendingPathComponent("Originals", isDirectory: true)
            let exporter = VerifiedExportService()
            var exportedCount = 0
            for asset in assets.sorted(by: { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }) {
                let sourceURL = originalsURL.appendingPathComponent(asset.storageKey.rawValue, isDirectory: false)
                let destinationURL = destinationDirectoryURL.appendingPathComponent(asset.filename, isDirectory: false)
                _ = try await exporter.export(sourceURL: sourceURL, to: destinationURL)
                exportedCount += 1
            }
            _ = exportedCount
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshDuplicateCandidates() async {
        guard let repository = container.blobRepository else { return }
        do {
            duplicateCandidates = try await repository.duplicateCandidates()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setFavorite(_ favorite: Bool) async {
        guard !selectedAssetIDs.isEmpty, let repository = container.assetRepository else { return }
        do {
            try await repository.updateFavorite(favorite, for: selectedAssetIDs)
            await refreshInspectorNow()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setRating(_ rating: AssetRating) async {
        guard !selectedAssetIDs.isEmpty, let repository = container.assetRepository else { return }
        do {
            try await repository.updateRating(rating, for: selectedAssetIDs)
            await refreshInspectorNow()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func libraryStateDidChange() {
        folderObservationTask?.cancel()
        albumObservationTask?.cancel()
        tagObservationTask?.cancel()
        savedSearchObservationTask?.cancel()
        smartCollectionObservationTask?.cancel()
        folderObservationTask = nil
        albumObservationTask = nil
        tagObservationTask = nil
        savedSearchObservationTask = nil
        smartCollectionObservationTask = nil

        guard case .ready = container.libraryState,
              let folderRepository = container.folderRepository,
              let albumRepository = container.albumRepository,
              let tagRepository = container.tagRepository,
              let savedSearchRepository = container.savedSearchRepository,
              let smartCollectionRepository = container.smartCollectionRepository else {
            folderTreeSnapshot = nil
            albums = []
            tags = []
            savedSearches = []
            smartCollections = []
            return
        }

        restartAssetObservation()

        folderObservationTask = Task { [weak self] in
            do {
                for try await snapshot in folderRepository.observeTree() {
                    guard let self, !Task.isCancelled else { return }
                    applyFolderSnapshot(snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }

        albumObservationTask = Task { [weak self] in
            do {
                for try await observedAlbums in albumRepository.observeAlbums() {
                    guard let self, !Task.isCancelled else { return }
                    albums = observedAlbums
                }
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }

        tagObservationTask = Task { [weak self] in
            do {
                for try await observedTags in tagRepository.observeTags() {
                    guard let self, !Task.isCancelled else { return }
                    tags = observedTags
                    if case let .tag(selectedID) = navigationTarget,
                       !observedTags.contains(where: { $0.id == selectedID }) {
                        navigationTarget = .allAssets
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }

        savedSearchObservationTask = Task { [weak self] in
            do {
                for try await observedSavedSearches in savedSearchRepository.observeSavedSearches() {
                    guard let self, !Task.isCancelled else { return }
                    savedSearches = observedSavedSearches
                    if case let .savedSearch(selectedID) = navigationTarget,
                       !observedSavedSearches.contains(where: { $0.id == selectedID }) {
                        navigationTarget = .allAssets
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }

        smartCollectionObservationTask = Task { [weak self] in
            do {
                for try await observedSmartCollections in smartCollectionRepository.observeSmartCollections() {
                    guard let self, !Task.isCancelled else { return }
                    smartCollections = observedSmartCollections
                    if case let .smartCollection(selectedID) = navigationTarget,
                       !observedSmartCollections.contains(where: { $0.id == selectedID }) {
                        navigationTarget = .allAssets
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    func saveCurrentSearch() async {
        guard let repository = container.savedSearchRepository else { return }
        do {
            _ = try await repository.createSavedSearch(
                named: nextAvailableName(base: "Saved Search", existingNames: savedSearches.map(\.name)),
                query: assetQuery
            )
            savedSearches = try await repository.savedSearches()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createSmartCollectionFromCurrentQuery() async {
        guard let repository = container.smartCollectionRepository else { return }
        do {
            let smartCollection = try await repository.createSmartCollection(
                named: nextAvailableName(base: "Smart Collection", existingNames: smartCollections.map(\.name)),
                query: assetQuery
            )
            smartCollections = try await repository.smartCollections()
            navigationTarget = .smartCollection(smartCollection.id)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applySmartCollection(_ smartCollection: SmartCollection) {
        searchText = smartCollection.query.criteria.text ?? ""
        navigationTarget = .smartCollection(smartCollection.id)
    }

    func applySavedSearch(_ savedSearch: SavedSearch) {
        searchText = savedSearch.query.criteria.text ?? ""
        navigationTarget = .savedSearch(savedSearch.id)
    }

    func updateSearchCriteria(_ criteria: AssetSearchCriteria) {
        searchText = criteria.text ?? ""
        assetQuery.criteria = criteria
        restartAssetObservation()
    }

    func renameSavedSearch(_ savedSearchID: SavedSearchID, to proposedName: String) async {
        guard let repository = container.savedSearchRepository else { return }
        do {
            try await repository.renameSavedSearch(savedSearchID, to: proposedName)
            savedSearches = try await repository.savedSearches()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteSavedSearch(_ savedSearchID: SavedSearchID) async {
        guard let repository = container.savedSearchRepository else { return }
        do {
            try await repository.deleteSavedSearch(savedSearchID)
            savedSearches = try await repository.savedSearches()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameSmartCollection(_ smartCollectionID: SmartCollectionID, to proposedName: String) async {
        guard let repository = container.smartCollectionRepository else { return }
        do {
            try await repository.renameSmartCollection(smartCollectionID, to: proposedName)
            smartCollections = try await repository.smartCollections()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteSmartCollection(_ smartCollectionID: SmartCollectionID) async {
        guard let repository = container.smartCollectionRepository else { return }
        do {
            try await repository.deleteSmartCollection(smartCollectionID)
            smartCollections = try await repository.smartCollections()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createAlbum() async {
        guard let repository = container.albumRepository else { return }
        do {
            let album = try await repository.createAlbum(named: nextAvailableAlbumName())
            albums = try await repository.albums()
            navigationTarget = .album(album.id)
            recordAction(named: "Create Album", undo: .deleteAlbum(album.id))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createTag() async {
        guard let repository = container.tagRepository else { return }
        do {
            let tag = try await repository.createTag(named: nextAvailableTagName())
            tags = try await repository.tags()
            recordAction(named: "Create Tag", undo: .deleteTag(tag.id))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameAlbum(_ albumID: AlbumID, to proposedName: String) async {
        guard let previousName = albums.first(where: { $0.id == albumID })?.name,
              let repository = container.albumRepository else { return }
        do {
            guard proposedName != previousName else { return }
            try await repository.renameAlbum(albumID, to: proposedName)
            albums = try await repository.albums()
            recordAction(named: "Rename Album", undo: .renameAlbum(albumID, to: previousName))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteAlbum(_ albumID: AlbumID) async {
        guard let repository = container.albumRepository else { return }
        do {
            let receipt = try await repository.deleteAlbum(albumID)
            albums = try await repository.albums()
            if case let .album(selectedID) = navigationTarget, selectedID == albumID {
                navigationTarget = .allAssets
            }
            recordAction(named: "Delete Album", undo: .restoreAlbum(receipt))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func moveAlbum(_ albumID: AlbumID, earlier: Bool) async {
        guard let repository = container.albumRepository,
              let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        let destinationIndex = earlier ? index - 1 : index + 1
        guard albums.indices.contains(destinationIndex) else { return }

        let priorOrder = albums.map(\.id)
        var reordered = albums
        reordered.swapAt(index, destinationIndex)
        do {
            try await repository.reorderAlbums(reordered.map(\.id))
            albums = try await repository.albums()
            recordAction(named: "Reorder Albums", undo: .reorderAlbums(priorOrder))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameTag(_ tagID: TagID, to proposedName: String) async {
        guard let previousName = tags.first(where: { $0.id == tagID })?.name,
              let repository = container.tagRepository else { return }
        do {
            guard proposedName != previousName else { return }
            try await repository.renameTag(tagID, to: proposedName)
            tags = try await repository.tags()
            recordAction(named: "Rename Tag", undo: .renameTag(tagID, to: previousName))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteTag(_ tagID: TagID) async {
        guard let repository = container.tagRepository else { return }
        do {
            let receipt = try await repository.deleteTag(tagID)
            tags = try await repository.tags()
            if case let .tag(selectedID) = navigationTarget, selectedID == tagID {
                navigationTarget = .allAssets
            }
            recordAction(named: "Delete Tag", undo: .restoreTag(receipt))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addTag(_ tagID: TagID) async {
        guard !selectedAssetIDs.isEmpty, let repository = container.tagRepository else { return }
        do {
            try await repository.addTags([tagID], to: selectedAssetIDs)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeTag(_ tagID: TagID) async {
        guard !selectedAssetIDs.isEmpty, let repository = container.tagRepository else { return }
        do {
            try await repository.removeTags([tagID], from: selectedAssetIDs)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createFolder(in parentFolderID: FolderID?) async {
        guard let repository = container.folderRepository else { return }
        do {
            let name = try nextAvailableFolderName(in: parentFolderID)
            let folder = try await repository.createFolder(named: name, in: parentFolderID)
            try await refreshFolderSnapshot(using: repository)
            if let parentFolderID {
                expandedFolderIDs.insert(parentFolderID)
            }
            navigationTarget = .folder(folder.id)
            recordAction(named: "Create Folder", undo: .deleteFolder(folder.id))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameFolder(_ folderID: FolderID, to proposedName: String) async {
        guard let previousName = folderTreeSnapshot?.folders.first(where: { $0.id == folderID })?.name else {
            return
        }
        do {
            let name = try FolderName(proposedName)
            guard name != previousName else { return }
            guard let repository = container.folderRepository else { return }
            try await repository.renameFolder(folderID, to: name)
            try await refreshFolderSnapshot(using: repository)
            recordAction(named: "Rename Folder", undo: .renameFolder(folderID, to: previousName))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reparentFolder(_ folderID: FolderID, to parentFolderID: FolderID?) async {
        guard let folder = folderTreeSnapshot?.folders.first(where: { $0.id == folderID }) else { return }
        let priorParentID = folder.parentFolderID
        guard priorParentID != parentFolderID else { return }
        guard let repository = container.folderRepository else { return }
        do {
            try await repository.reparentFolder(folderID, to: parentFolderID)
            try await refreshFolderSnapshot(using: repository)
            if let parentFolderID {
                expandedFolderIDs.insert(parentFolderID)
            }
            recordAction(named: "Move Folder", undo: .reparentFolder(folderID, to: priorParentID))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func prepareToDeleteFolder(_ folderID: FolderID) async {
        guard let snapshot = folderTreeSnapshot,
              let folder = snapshot.folders.first(where: { $0.id == folderID }),
              folder.systemKind == nil else {
            return
        }

        let folderIDs = descendantFolderIDs(startingAt: folderID, in: snapshot)
        var assetCount = 0
        if let assetRepository = container.assetRepository {
            do {
                for id in folderIDs {
                    assetCount += try await assetRepository.count(matching: AssetQuery(scope: .folder(id)))
                }
            } catch {
                statusMessage = error.localizedDescription
                return
            }
        }

        pendingFolderDeletion = FolderDeletionPrompt(
            folderID: folderID,
            folderName: folder.name.rawValue,
            folderCount: folderIDs.count,
            assetCount: assetCount
        )
    }

    func deleteFolder(_ prompt: FolderDeletionPrompt) async {
        guard let repository = container.folderRepository else { return }

        do {
            let receipt = try await repository.deletePreservingAssets(prompt.folderID)
            try await refreshFolderSnapshot(using: repository)
            if case let .folder(selectedID) = navigationTarget,
               receipt.deletedFolders.contains(where: { $0.id == selectedID }) {
                navigationTarget = .inbox
            }
            recordAction(named: "Delete Folder", undo: .restoreFolder(receipt))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func cancelPendingFolderDeletion() {
        pendingFolderDeletion = nil
    }

    func canReparentFolder(_ folderID: FolderID, to parentFolderID: FolderID?) -> Bool {
        guard let snapshot = folderTreeSnapshot,
              let folder = snapshot.folders.first(where: { $0.id == folderID }),
              folder.systemKind == nil,
              folder.parentFolderID != parentFolderID,
              folderID != parentFolderID else {
            return false
        }
        if let parentFolderID {
            guard snapshot.folders.contains(where: { $0.id == parentFolderID && $0.systemKind == nil }) else {
                return false
            }
            return !descendantFolderIDs(startingAt: folderID, in: snapshot).contains(parentFolderID)
        }
        return true
    }

    private func applyFolderSnapshot(_ snapshot: FolderTreeSnapshot) {
        folderTreeSnapshot = snapshot
        let validIDs = Set(snapshot.folders.map(\.id))
        expandedFolderIDs.formIntersection(validIDs)
        if case let .folder(selectedID) = navigationTarget, !validIDs.contains(selectedID) {
            navigationTarget = .inbox
        }
    }

    private var importDestinationFolderID: FolderID? {
        if case let .folder(folderID) = navigationTarget {
            return folderID
        }
        return folderTreeSnapshot?.inboxID ?? container.catalogDatabase?.inboxID
    }

    private func applyImportProgress(_ progress: ImportProgress) {
        importProgress = progress
    }

    private func restartAssetObservation() {
        observationTask?.cancel()
        observationTask = nil
        cancelThumbnailWork(clearStates: true)

        guard case .ready = container.libraryState,
              let repository = container.assetRepository else {
            orderedVisibleAssetIDs = []
            return
        }

        let query = assetQuery
        let sort = assetSort
        observationTask = Task { [weak self] in
            do {
                for try await _ in repository.observe(matching: query) {
                    guard let self, !Task.isCancelled,
                          query == assetQuery,
                          sort == assetSort else { return }
                    try await loadAssetState(repository: repository, query: query, sort: sort)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    private func refreshVisibleAssetIDs() async throws {
        guard let repository = container.assetRepository else { return }
        try await loadAssetState(repository: repository, query: assetQuery, sort: assetSort)
    }

    private func loadAssetState(
        repository: any AssetRepository,
        query: AssetQuery,
        sort: AssetSort
    ) async throws {
        async let ids = repository.orderedIDs(matching: query, sortedBy: sort)
        async let page = repository.page(matching: query, sortedBy: sort, offset: 0, limit: 200)
        orderedVisibleAssetIDs = try await ids
        assetGridRecords = try await page.records
        selectedAssetIDs.formIntersection(orderedVisibleAssetIDs)
    }

    private func cancelThumbnailWork(clearStates: Bool) {
        thumbnailPrefetchTask?.cancel()
        thumbnailPrefetchTask = nil
        for (_, entry) in thumbnailTasks {
            entry.1.cancel()
            Task { await container.thumbnailProvider?.cancel(requestID: entry.0) }
        }
        thumbnailTasks.removeAll()
        if clearStates {
            thumbnailStates.removeAll()
        }
    }

    private func scheduleInspectorRefresh() {
        inspectorTask?.cancel()
        inspectorPreviewTask?.cancel()
        if let requestID = inspectorPreviewRequestID {
            Task { await container.thumbnailProvider?.cancel(requestID: requestID) }
        }
        inspectorPreviewRequestID = nil
        selectedAssets = []
        trashEntriesByAssetID = [:]
        inspectorSelectionIsLimited = selectedAssetIDs.count > 500
        inspectorPreviewState = nil
        guard !selectedAssetIDs.isEmpty, !inspectorSelectionIsLimited else { return }

        inspectorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            await refreshInspectorNow()
        }
    }

    private func refreshInspectorNow() async {
        guard let repository = container.assetRepository else { return }
        let selection = selectedAssetIDs
        do {
            let assets = try await repository.assets(ids: selection)
            guard selection == selectedAssetIDs else { return }
            selectedAssets = assets.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if navigationTarget == .trash {
                trashEntriesByAssetID = Dictionary(
                    uniqueKeysWithValues: try await repository.trashEntries(assetIDs: selection).map { ($0.assetID, $0) }
                )
            } else {
                trashEntriesByAssetID = [:]
            }
            if assets.count == 1, let asset = assets.first {
                requestInspectorPreview(for: asset)
            } else {
                inspectorPreviewState = nil
            }
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func requestInspectorPreview(for asset: Asset) {
        guard let provider = container.thumbnailProvider else { return }
        inspectorPreviewTask?.cancel()
        let request = ThumbnailRequest(
            storageKey: asset.storageKey,
            fingerprint: AssetFingerprint(
                assetID: asset.id,
                fileSize: asset.fileSize,
                modifiedAtMilliseconds: Int64(asset.modifiedAt.timeIntervalSince1970 * 1_000)
            ),
            target: ThumbnailTarget(width: 720, height: 720, displayScale: 1)
        )
        inspectorPreviewRequestID = request.id
        inspectorPreviewState = .loading
        inspectorPreviewTask = Task { [weak self] in
            do {
                let payload = try await provider.preview(for: request)
                guard let self, !Task.isCancelled, selectedAssetIDs == Set([asset.id]) else { return }
                inspectorPreviewState = .ready(payload)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                let available = await container.assetBlobStore?.validate(asset.storageKey) ?? false
                inspectorPreviewState = available ? .corrupt : .missing
            }
            self?.inspectorPreviewRequestID = nil
        }
    }

    private func nextAvailableFolderName(in parentFolderID: FolderID?) throws -> FolderName {
        let existingNames = Set(
            folderTreeSnapshot?.folders
                .filter { $0.parentFolderID == parentFolderID }
                .map { $0.name.rawValue.lowercased() } ?? []
        )
        var candidate = "New Folder"
        var suffix = 2
        while existingNames.contains(candidate.lowercased()) {
            candidate = "New Folder \(suffix)"
            suffix += 1
        }
        return try FolderName(candidate)
    }

    private func nextAvailableAlbumName() -> String {
        nextAvailableName(base: "New Album", existingNames: albums.map(\.name))
    }

    private func nextAvailableTagName() -> String {
        nextAvailableName(base: "New Tag", existingNames: tags.map(\.name))
    }

    private func nextAvailableName(base: String, existingNames: [String]) -> String {
        let existing = Set(existingNames.map { $0.lowercased() })
        var candidate = base
        var suffix = 2
        while existing.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func descendantFolderIDs(startingAt folderID: FolderID, in snapshot: FolderTreeSnapshot) -> [FolderID] {
        var result: [FolderID] = []
        var pending = [folderID]
        while let current = pending.popLast() {
            result.append(current)
            pending.append(contentsOf: snapshot.childrenByParent[current, default: []])
        }
        return result
    }

    private func recordAction(named actionName: String, undo action: LibraryHistoryAction) {
        undoHistory.append(LibraryHistoryEntry(actionName: actionName, action: action))
        redoHistory.removeAll()
    }

    private func performHistoryAction(_ action: LibraryHistoryAction) async throws -> LibraryHistoryAction {
        switch action {
        case let .renameFolder(folderID, name):
            guard let repository = container.folderRepository else {
                throw LibraryHistoryError.folderUnavailable
            }
            guard let currentName = folderTreeSnapshot?.folders.first(where: { $0.id == folderID })?.name else {
                throw LibraryHistoryError.folderUnavailable
            }
            try await repository.renameFolder(folderID, to: name)
            try await refreshFolderSnapshot(using: repository)
            return .renameFolder(folderID, to: currentName)

        case let .reparentFolder(folderID, parentFolderID):
            guard let repository = container.folderRepository else {
                throw LibraryHistoryError.folderUnavailable
            }
            guard let currentFolder = folderTreeSnapshot?.folders.first(where: { $0.id == folderID }) else {
                throw LibraryHistoryError.folderUnavailable
            }
            let currentParentID = currentFolder.parentFolderID
            try await repository.reparentFolder(folderID, to: parentFolderID)
            try await refreshFolderSnapshot(using: repository)
            if let parentFolderID {
                expandedFolderIDs.insert(parentFolderID)
            }
            return .reparentFolder(folderID, to: currentParentID)

        case let .deleteFolder(folderID):
            guard let repository = container.folderRepository else {
                throw LibraryHistoryError.folderUnavailable
            }
            let receipt = try await repository.deletePreservingAssets(folderID)
            try await refreshFolderSnapshot(using: repository)
            if case let .folder(selectedID) = navigationTarget,
               receipt.deletedFolders.contains(where: { $0.id == selectedID }) {
                navigationTarget = .inbox
            }
            return .restoreFolder(receipt)

        case let .restoreFolder(receipt):
            guard let repository = container.folderRepository else {
                throw LibraryHistoryError.folderUnavailable
            }
            try await repository.restoreDeletedFolder(using: receipt)
            try await refreshFolderSnapshot(using: repository)
            guard let rootID = deletedRootID(in: receipt) else {
                throw LibraryHistoryError.folderUnavailable
            }
            navigationTarget = .folder(rootID)
            return .deleteFolder(rootID)

        case let .renameAlbum(albumID, name):
            guard let repository = container.albumRepository,
                  let currentName = albums.first(where: { $0.id == albumID })?.name else {
                throw LibraryHistoryError.albumUnavailable
            }
            try await repository.renameAlbum(albumID, to: name)
            albums = try await repository.albums()
            return .renameAlbum(albumID, to: currentName)

        case let .reorderAlbums(albumIDs):
            guard let repository = container.albumRepository else {
                throw LibraryHistoryError.albumUnavailable
            }
            let priorOrder = albums.map(\.id)
            try await repository.reorderAlbums(albumIDs)
            albums = try await repository.albums()
            return .reorderAlbums(priorOrder)

        case let .deleteAlbum(albumID):
            guard let repository = container.albumRepository else {
                throw LibraryHistoryError.albumUnavailable
            }
            let receipt = try await repository.deleteAlbum(albumID)
            albums = try await repository.albums()
            if case let .album(selectedID) = navigationTarget, selectedID == albumID {
                navigationTarget = .allAssets
            }
            return .restoreAlbum(receipt)

        case let .restoreAlbum(receipt):
            guard let repository = container.albumRepository else {
                throw LibraryHistoryError.albumUnavailable
            }
            try await repository.restoreDeletedAlbum(using: receipt)
            albums = try await repository.albums()
            navigationTarget = .album(receipt.album.id)
            return .deleteAlbum(receipt.album.id)

        case let .renameTag(tagID, name):
            guard let repository = container.tagRepository,
                  let currentName = tags.first(where: { $0.id == tagID })?.name else {
                throw LibraryHistoryError.tagUnavailable
            }
            try await repository.renameTag(tagID, to: name)
            tags = try await repository.tags()
            return .renameTag(tagID, to: currentName)

        case let .renameAsset(assetID, name):
            guard let repository = container.assetRepository,
                  let currentAsset = try await repository.asset(id: assetID) else {
                throw LibraryHistoryError.folderUnavailable
            }
            try await repository.updateDisplayName(name, for: assetID)
            await refreshInspectorNow()
            return .renameAsset(assetID, to: currentAsset.displayName)

        case let .restoreAssetLocations(receipt):
            guard let repository = container.assetRepository else {
                throw LibraryHistoryError.folderUnavailable
            }
            return .restoreAssetLocations(try await repository.restoreAssetLocations(using: receipt))

        case let .deleteTag(tagID):
            guard let repository = container.tagRepository else {
                throw LibraryHistoryError.tagUnavailable
            }
            let receipt = try await repository.deleteTag(tagID)
            tags = try await repository.tags()
            if case let .tag(selectedID) = navigationTarget, selectedID == tagID {
                navigationTarget = .allAssets
            }
            return .restoreTag(receipt)

        case let .restoreTag(receipt):
            guard let repository = container.tagRepository else {
                throw LibraryHistoryError.tagUnavailable
            }
            try await repository.restoreDeletedTag(using: receipt)
            tags = try await repository.tags()
            navigationTarget = .tag(receipt.tag.id)
            return .deleteTag(receipt.tag.id)

        case let .restoreTrash(receipt):
            guard let repository = container.assetRepository else {
                throw LibraryHistoryError.folderUnavailable
            }
            try await repository.restoreFromTrash(using: receipt)
            return .moveToTrash(Set(receipt.entries.map(\.assetID)))

        case let .moveToTrash(assetIDs):
            guard let repository = container.assetRepository else {
                throw LibraryHistoryError.folderUnavailable
            }
            let receipt = try await repository.moveToTrash(assetIDs, retentionDays: 30)
            return .restoreTrash(receipt)
        }
    }

    private func refreshFolderSnapshot(using repository: any FolderRepository) async throws {
        applyFolderSnapshot(try await repository.treeSnapshot())
    }

    private func queryForNavigationTarget() -> AssetQuery {
        if case let .savedSearch(savedSearchID) = navigationTarget,
           let savedSearch = savedSearches.first(where: { $0.id == savedSearchID }) {
            return savedSearch.query
        }
        if case let .smartCollection(smartCollectionID) = navigationTarget,
           let smartCollection = smartCollections.first(where: { $0.id == smartCollectionID }) {
            return smartCollection.query
        }
        return AssetQuery(
            scope: navigationTarget.assetScope,
            criteria: AssetSearchCriteria(text: searchText)
        )
    }

    private func deletedRootID(in receipt: FolderDeletionReceipt) -> FolderID? {
        let deletedIDs = Set(receipt.deletedFolders.map(\.id))
        return receipt.deletedFolders.first { folder in
            guard let parentID = folder.parentFolderID else { return true }
            return !deletedIDs.contains(parentID)
        }?.id
    }
}
