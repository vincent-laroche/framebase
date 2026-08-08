import FramebaseDomain
import Foundation
import Observation

struct FolderDeletionPrompt: Identifiable, Sendable {
    let folderID: FolderID
    let folderName: String
    let folderCount: Int
    let assetCount: Int

    var id: FolderID { folderID }
}

private struct FolderHistoryEntry: Sendable {
    let actionName: String
    let action: FolderHistoryAction
}

private enum FolderHistoryAction: Sendable {
    case rename(FolderID, to: FolderName)
    case reparent(FolderID, to: FolderID?)
    case delete(FolderID)
    case restore(FolderDeletionReceipt)
}

private enum FolderHistoryError: LocalizedError {
    case folderUnavailable

    var errorDescription: String? {
        "The folder is no longer available for that history action."
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
            restartAssetObservation()
        }
    }
    var assetQuery = AssetQuery(scope: .allAssets)
    var assetSort = AssetSort.defaultSort {
        didSet { restartAssetObservation() }
    }
    var orderedVisibleAssetIDs: [AssetID] = []
    var assetGridRecords: [AssetGridRecord] = []
    var thumbnailStates: [AssetID: AssetThumbnailState] = [:]
    var selectedAssetIDs: Set<AssetID> = []
    var selectionAnchorID: AssetID?
    var keyboardFocusedAssetID: AssetID?
    var expandedFolderIDs: Set<FolderID> = []
    var isSidebarKeyboardFocused = false
    var sidebarFocusRequestGeneration = 0
    var folderTreeSnapshot: FolderTreeSnapshot?
    var albums: [Album] = []
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

    private var undoHistory: [FolderHistoryEntry] = []
    private var redoHistory: [FolderHistoryEntry] = []
    private var isApplyingFolderHistory = false

    var canUndoFolderAction: Bool { !undoHistory.isEmpty && !isApplyingFolderHistory }
    var canRedoFolderAction: Bool { !redoHistory.isEmpty && !isApplyingFolderHistory }
    var undoFolderActionName: String { undoHistory.last.map { "Undo \($0.actionName)" } ?? "Undo" }
    var redoFolderActionName: String { redoHistory.last.map { "Redo \($0.actionName)" } ?? "Redo" }

    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTasks: [AssetID: (ThumbnailRequestID, Task<Void, Never>)] = [:]
    @ObservationIgnored private var folderObservationTask: Task<Void, Never>?
    @ObservationIgnored private var albumObservationTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    deinit {
        observationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
        for (_, entry) in thumbnailTasks { entry.1.cancel() }
        folderObservationTask?.cancel()
        albumObservationTask?.cancel()
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
        guard !isApplyingFolderHistory, let entry = undoHistory.popLast() else { return }
        isApplyingFolderHistory = true
        defer { isApplyingFolderHistory = false }
        do {
            let inverse = try await performFolderHistoryAction(entry.action)
            redoHistory.append(FolderHistoryEntry(actionName: entry.actionName, action: inverse))
        } catch {
            undoHistory.append(entry)
            statusMessage = error.localizedDescription
        }
    }

    func redoLastAction() async {
        guard !isApplyingFolderHistory, let entry = redoHistory.popLast() else { return }
        isApplyingFolderHistory = true
        defer { isApplyingFolderHistory = false }
        do {
            let inverse = try await performFolderHistoryAction(entry.action)
            undoHistory.append(FolderHistoryEntry(actionName: entry.actionName, action: inverse))
        } catch {
            redoHistory.append(entry)
            statusMessage = error.localizedDescription
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
        thumbnailStates[record.id] = .loading
        let task = Task { [weak self] in
            do {
                let payload = try await provider.thumbnail(for: request)
                guard let self, !Task.isCancelled else { return }
                thumbnailStates[record.id] = .ready(payload)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                let originalAvailable = await container.assetBlobStore?.validate(record.storageKey) ?? false
                thumbnailStates[record.id] = originalAvailable ? .corrupt : .missing
            }
            self?.thumbnailTasks.removeValue(forKey: record.id)
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

    func libraryStateDidChange() {
        folderObservationTask?.cancel()
        albumObservationTask?.cancel()
        folderObservationTask = nil
        albumObservationTask = nil

        guard case .ready = container.libraryState,
              let folderRepository = container.folderRepository,
              let albumRepository = container.albumRepository else {
            folderTreeSnapshot = nil
            albums = []
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
            recordFolderAction(named: "Create Folder", undo: .delete(folder.id))
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
            recordFolderAction(named: "Rename Folder", undo: .rename(folderID, to: previousName))
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
            recordFolderAction(named: "Move Folder", undo: .reparent(folderID, to: priorParentID))
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
            recordFolderAction(named: "Delete Folder", undo: .restore(receipt))
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

    private func descendantFolderIDs(startingAt folderID: FolderID, in snapshot: FolderTreeSnapshot) -> [FolderID] {
        var result: [FolderID] = []
        var pending = [folderID]
        while let current = pending.popLast() {
            result.append(current)
            pending.append(contentsOf: snapshot.childrenByParent[current, default: []])
        }
        return result
    }

    private func recordFolderAction(named actionName: String, undo action: FolderHistoryAction) {
        undoHistory.append(FolderHistoryEntry(actionName: actionName, action: action))
        redoHistory.removeAll()
    }

    private func performFolderHistoryAction(_ action: FolderHistoryAction) async throws -> FolderHistoryAction {
        guard let repository = container.folderRepository else {
            throw FolderHistoryError.folderUnavailable
        }

        switch action {
        case let .rename(folderID, name):
            guard let currentName = folderTreeSnapshot?.folders.first(where: { $0.id == folderID })?.name else {
                throw FolderHistoryError.folderUnavailable
            }
            try await repository.renameFolder(folderID, to: name)
            try await refreshFolderSnapshot(using: repository)
            return .rename(folderID, to: currentName)

        case let .reparent(folderID, parentFolderID):
            guard let currentFolder = folderTreeSnapshot?.folders.first(where: { $0.id == folderID }) else {
                throw FolderHistoryError.folderUnavailable
            }
            let currentParentID = currentFolder.parentFolderID
            try await repository.reparentFolder(folderID, to: parentFolderID)
            try await refreshFolderSnapshot(using: repository)
            if let parentFolderID {
                expandedFolderIDs.insert(parentFolderID)
            }
            return .reparent(folderID, to: currentParentID)

        case let .delete(folderID):
            let receipt = try await repository.deletePreservingAssets(folderID)
            try await refreshFolderSnapshot(using: repository)
            if case let .folder(selectedID) = navigationTarget,
               receipt.deletedFolders.contains(where: { $0.id == selectedID }) {
                navigationTarget = .inbox
            }
            return .restore(receipt)

        case let .restore(receipt):
            try await repository.restoreDeletedFolder(using: receipt)
            try await refreshFolderSnapshot(using: repository)
            guard let rootID = deletedRootID(in: receipt) else {
                throw FolderHistoryError.folderUnavailable
            }
            navigationTarget = .folder(rootID)
            return .delete(rootID)
        }
    }

    private func refreshFolderSnapshot(using repository: any FolderRepository) async throws {
        applyFolderSnapshot(try await repository.treeSnapshot())
    }

    private func deletedRootID(in receipt: FolderDeletionReceipt) -> FolderID? {
        let deletedIDs = Set(receipt.deletedFolders.map(\.id))
        return receipt.deletedFolders.first { folder in
            guard let parentID = folder.parentFolderID else { return true }
            return !deletedIDs.contains(parentID)
        }?.id
    }
}
