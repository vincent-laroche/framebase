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

struct WorkflowTagPreview: Identifiable, Sendable {
    let workflowRunID: UUID
    let plan: WorkflowPlan
    let tagName: TagName

    var id: UUID { workflowRunID }
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
    case trash
    case folder(FolderID)
    case album(AlbumID)

    var title: String {
        switch self {
        case .allAssets: "All Assets"
        case .inbox: "Inbox"
        case .favorites: "Favorites"
        case .trash: "Trash"
        case .folder: "Folder"
        case .album: "Album"
        }
    }

    var assetScope: AssetScope {
        switch self {
        case .allAssets: .allAssets
        case .inbox: .inbox
        case .favorites: .favorites
        case .trash: .trash
        case let .folder(id): .folder(id)
        case let .album(id): .album(id)
        }
    }
}

enum AssetBrowserPresentation: String, Sendable {
    case grid
    case list
}

@MainActor
@Observable
final class LibraryWindowModel {
    let container: AppContainer

    var navigationTarget: NavigationTarget = .allAssets {
        didSet {
            assetQuery = AssetQuery(scope: navigationTarget.assetScope, filter: assetFilter)
            restartAssetObservation()
        }
    }
    var assetQuery = AssetQuery(scope: .allAssets)
    var assetFilter = AssetFilter() {
        didSet {
            guard assetFilter != oldValue else { return }
            assetQuery = AssetQuery(scope: navigationTarget.assetScope, filter: assetFilter)
            restartAssetObservation()
        }
    }
    var searchText = "" {
        didSet { assetFilter.text = searchText }
    }
    var recognizedTextSearch = "" {
        didSet { assetFilter.recognizedText = recognizedTextSearch }
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
    var selectedAnalysisResults: [AssetAnalysisResult] = []
    var selectedPhotoAssessments: [PhotoAssessment] = []
    var selectedAssessmentReviews: [UUID: [AssessmentReview]] = [:]
    var selectedBeforeAfterRelationships: [BeforeAfterRelationship] = []
    var isAnalyzingSelection = false
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
    var selectedTags: [Tag] = []
    var selectedDuplicateCandidate: DuplicateCandidate?
    var selectedTrashReceipts: [AssetTrashReceipt] = []
    var savedSearches: [SavedSearch] = []
    var hairSolutionsTemplatePreview: LibraryTemplateApplicationPreview?
    var workflowTagPreview: WorkflowTagPreview?
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
    @ObservationIgnored private var tagObservationTask: Task<Void, Never>?
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

            try await container.synchronizeCloudImportedAssets(Set(result.importedAssetIDs))

#if DEBUG
            try await seedSyntheticVisualAssessmentForUITestIfRequested(assetIDs: result.importedAssetIDs)
#endif

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

#if DEBUG
    /// UI tests opt into this generated fixture through an environment flag so
    /// they exercise the app's repository path without a second SQLite writer.
    private func seedSyntheticVisualAssessmentForUITestIfRequested(assetIDs: [AssetID]) async throws {
        guard ProcessInfo.processInfo.environment["FRAMEBASE_UI_TEST_SEED_VISUAL_ASSESSMENT"] == "1",
              let assetID = assetIDs.first,
              let catalog = container.catalogDatabase else { return }
        let assessment = try PhotoAssessment(
            assetID: assetID,
            businessQuality: .strong,
            evidence: [.sharp],
            photoRole: .afterCandidate,
            hairlinePresentation: .clearlyVisible,
            confidence: 0.9,
            rationale: "Synthetic review fixture",
            modelRevision: VisualModelRevision(provider: .local, modelIdentifier: "ui-fixture", assessmentSchemaVersion: 1),
            derivativeSHA256: String(repeating: "a", count: 64),
            derivativeMaximumPixelDimension: 1_600,
            capturedAt: .now
        )
        try await catalog.visualLearning.store(assessment)
    }
#endif

    func undoLastAction() async {
        guard !container.cloudBackingIsActive else {
            statusMessage = "Folder undo is unavailable while cloud backing is active."
            return
        }
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
        guard !container.cloudBackingIsActive else {
            statusMessage = "Folder redo is unavailable while cloud backing is active."
            return
        }
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
        case .allAssets, .favorites, .album, .trash: return true
        }
    }

    var availableMoveDestinations: [Folder] {
        (folderTreeSnapshot?.folders ?? [])
            .filter { folder in
                canMoveAssets(selectedAssetIDs, to: folder.id)
            }
    }

    func moveAssets(_ assetIDs: Set<AssetID>, to folderID: FolderID) async {
        guard canMoveAssets(assetIDs, to: folderID),
              let repository = container.assetRepository else { return }
        do {
            try await repository.moveAssets(assetIDs, to: folderID)
            try await container.queueCloudAssetMutation(.move(to: folderID), for: assetIDs)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameSelectedAsset(to proposedName: String) async {
        guard selectedAssetIDs.count == 1,
              let assetID = selectedAssetIDs.first,
              let repository = container.assetRepository else {
            return
        }
        do {
            try await repository.updateDisplayName(proposedName, for: assetID)
            try await container.queueCloudAssetMutation(.rename(displayName: proposedName), for: [assetID])
            await refreshInspectorNow()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportSelectedAssets(to destinationDirectoryURL: URL) async {
        guard !selectedAssetIDs.isEmpty,
              let repository = container.assetRepository,
              let blobStore = container.assetBlobStore,
              let catalog = container.catalogDatabase else { return }
        do {
            let assets = try await repository.assets(ids: selectedAssetIDs)
            let result = try await AssetExporter(blobStore: blobStore).export(assets, to: destinationDirectoryURL)
            try await catalog.exports.record(result.receipt)
            try await container.queueCloudExportReceipt(result.receipt)
            statusMessage = "Exported \(assets.count) verified original\(assets.count == 1 ? "" : "s") with a manifest."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func revealOriginal(_ assetID: AssetID) async {
        guard let repository = container.assetRepository,
              let blobStore = container.assetBlobStore else { return }
        do {
            guard let asset = try await repository.assets(ids: [assetID]).first else { return }
            let originalURL = try await blobStore.resolve(asset.storageKey)
            NSWorkspace.shared.activateFileViewerSelecting([originalURL])
        } catch {
            statusMessage = "The original is not stored locally. Download the verified original first."
        }
    }

    func toggleTagFilter(_ tagID: TagID) {
        if assetFilter.tagIDs.contains(tagID) {
            assetFilter.tagIDs.remove(tagID)
        } else {
            assetFilter.tagIDs.insert(tagID)
        }
    }

    func setFavoriteFilter(_ favorite: Bool?) {
        assetFilter.favorite = favorite
    }

    func clearAssetFilters() {
        searchText = ""
        recognizedTextSearch = ""
        assetFilter = AssetFilter()
    }

    func saveCurrentSearch(named proposedName: String) async {
        guard let repository = container.savedSearchRepository else { return }
        do {
            let savedSearch = SavedSearch(name: try SavedSearchName(proposedName), filter: assetFilter, sort: assetSort)
            try await repository.save(savedSearch)
            try await container.queueCloudSavedSearchMutation(.save(savedSearch))
            savedSearches = try await repository.savedSearches()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applySavedSearch(_ savedSearch: SavedSearch) {
        assetFilter = savedSearch.filter
        searchText = savedSearch.filter.text ?? ""
        recognizedTextSearch = savedSearch.filter.recognizedText ?? ""
        assetSort = savedSearch.sort
        navigationTarget = .allAssets
    }

    func deleteSavedSearch(_ savedSearchID: SavedSearchID) async {
        guard let repository = container.savedSearchRepository else { return }
        do {
            try await repository.deleteSavedSearch(savedSearchID)
            try await container.queueCloudSavedSearchMutation(.delete(savedSearchID))
            savedSearches = try await repository.savedSearches()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setFavorite(_ favorite: Bool) async {
        guard !selectedAssetIDs.isEmpty, let repository = container.assetRepository else { return }
        do {
            try await repository.updateFavorite(favorite, for: selectedAssetIDs)
            try await container.queueCloudAssetMutation(.favorite(favorite), for: selectedAssetIDs)
            await refreshInspectorNow()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setRating(_ rating: AssetRating) async {
        guard !selectedAssetIDs.isEmpty, let repository = container.assetRepository else { return }
        do {
            try await repository.updateRating(rating, for: selectedAssetIDs)
            try await container.queueCloudAssetMutation(.rating(rating), for: selectedAssetIDs)
            await refreshInspectorNow()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createAlbum() async {
        guard let repository = container.albumRepository else { return }
        do {
            let album = try await repository.createAlbum(named: nextAvailableAlbumName())
            try await container.queueCloudAlbumMutation(.create(album))
            if !selectedAssetIDs.isEmpty {
                try await repository.addAssets(selectedAssetIDs, to: album.id)
                try await container.queueCloudAlbumMutation(.add(albumID: album.id, assetIDs: selectedAssetIDs))
            }
            navigationTarget = .album(album.id)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameAlbum(_ albumID: AlbumID, to proposedName: String) async {
        guard let repository = container.albumRepository else { return }
        do {
            try await repository.renameAlbum(albumID, to: proposedName)
            guard let album = try await repository.albums().first(where: { $0.id == albumID }) else { return }
            try await container.queueCloudAlbumMutation(.rename(album))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteAlbum(_ albumID: AlbumID) async {
        guard let repository = container.albumRepository else { return }
        do {
            try await repository.deleteAlbum(albumID)
            try await container.queueCloudAlbumMutation(.delete(albumID))
            if navigationTarget == .album(albumID) { navigationTarget = .allAssets }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addSelectedAssets(to albumID: AlbumID) async {
        guard !selectedAssetIDs.isEmpty,
              let repository = container.albumRepository else { return }
        do {
            try await repository.addAssets(selectedAssetIDs, to: albumID)
            try await container.queueCloudAlbumMutation(.add(albumID: albumID, assetIDs: selectedAssetIDs))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addTag(named proposedName: String) async {
        guard !selectedAssetIDs.isEmpty,
              let repository = container.tagRepository else { return }
        do {
            let name = try TagName(proposedName)
            let tag: Tag
            if let existingTag = tags.first(where: { $0.name == name }) {
                tag = existingTag
            } else {
                tag = try await repository.createTag(named: name)
                try await container.queueCloudTagMutation(.create(tag))
            }
            try await repository.addTags([tag.id], to: selectedAssetIDs)
            try await container.queueCloudTagMutation(.add(tag, assetIDs: selectedAssetIDs))
            await refreshInspectorNow()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeTag(_ tagID: TagID) async {
        guard !selectedAssetIDs.isEmpty,
              let repository = container.tagRepository else { return }
        do {
            try await repository.removeTags([tagID], from: selectedAssetIDs)
            guard let tag = tags.first(where: { $0.id == tagID }) else { return }
            try await container.queueCloudTagMutation(.remove(tag, assetIDs: selectedAssetIDs))
            await refreshInspectorNow()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func trashSelectedAssets() async {
        guard !selectedAssetIDs.isEmpty,
              let repository = container.assetRepository else { return }
        do {
            _ = try await repository.trashAssets(selectedAssetIDs, retentionDays: 30)
            try await container.queueCloudAssetMutation(.trash(retentionDays: 30), for: selectedAssetIDs)
            clearSelection()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restoreSelectedAssets() async {
        guard !selectedAssetIDs.isEmpty,
              let repository = container.assetRepository else { return }
        do {
            try await repository.restoreAssets(selectedAssetIDs)
            try await container.queueCloudAssetMutation(.restore, for: selectedAssetIDs)
            clearSelection()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func prepareHairSolutionsTemplateApplication() async {
        guard !container.cloudBackingIsActive, let catalog = container.catalogDatabase else { return }
        do {
            hairSolutionsTemplatePreview = try await catalog.previewHairSolutionsLibraryTemplate()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func dismissHairSolutionsTemplatePreview() {
        hairSolutionsTemplatePreview = nil
    }

    func applyHairSolutionsTemplate() async {
        guard !container.cloudBackingIsActive, let catalog = container.catalogDatabase else { return }
        do {
            let receipt = try await catalog.applyHairSolutionsLibraryTemplate()
            hairSolutionsTemplatePreview = nil
            statusMessage = "Added \(receipt.createdFolderIDs.count) template folders and \(receipt.createdTagIDs.count) tags. On-first-use folders were left empty."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func materializeOriginal(_ assetID: AssetID) async {
        guard let sync = container.cloudSync else { return }
        do {
            _ = try await sync.materializeOriginal(for: assetID)
            await container.refreshCloudStatus()
            await refreshInspectorNow()
            try await refreshVisibleAssetIDs()
            statusMessage = "The original was downloaded, verified, and restored to managed local storage."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func analyzeSelectedAssets() async {
        let selection = selectedAssetIDs
        guard !selection.isEmpty, !isAnalyzingSelection else { return }

        isAnalyzingSelection = true
        defer { isAnalyzingSelection = false }
        do {
            let results = try await container.analyzeLocally(
                assetIDs: selection,
                kinds: AnalysisKind.activeLocalVisionKinds
            )
            guard selection == selectedAssetIDs else { return }
            selectedAnalysisResults = results
            await refreshInspectorNow()
            statusMessage = "Finished local analysis for \(selection.count) image\(selection.count == 1 ? "" : "s"). Framebase did not change any folders, tags, or asset details."
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Records human visual-learning evidence only. This does not rename,
    /// move, tag, rate, favorite, delete, or otherwise organize an asset.
    func recordAssessmentReview(_ assessment: PhotoAssessment, decision: AssessmentReviewDecision) async {
        guard selectedAssetIDs == Set([assessment.assetID]), let catalog = container.catalogDatabase else { return }
        do {
            let review = try AssessmentReview(
                assessmentID: assessment.id,
                assetID: assessment.assetID,
                decision: decision,
                reviewedAt: .now
            )
            try await catalog.visualLearning.record(review)
            let outcome: AssessmentFeedbackOutcome = switch decision {
            case .accepted: .helpful
            case .rejected: .notHelpful
            case .needsMoreContext, .unreviewed, .corrected: .uncertain
            }
            try await catalog.visualLearning.record(
                AssessmentFeedbackEvent(assessmentID: assessment.id, reviewID: review.id, outcome: outcome, capturedAt: .now)
            )
            await refreshInspectorNow()
            statusMessage = "Recorded your visual-assessment review. Framebase did not organize this asset."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func recordAssessmentCorrection(
        _ assessment: PhotoAssessment,
        businessQuality: BusinessPhotoQuality,
        photoRole: PhotoRole,
        hairlinePresentation: HairlinePresentation
    ) async {
        guard selectedAssetIDs == Set([assessment.assetID]), let catalog = container.catalogDatabase else { return }
        do {
            let review = try AssessmentReview(
                assessmentID: assessment.id,
                assetID: assessment.assetID,
                decision: .corrected,
                correctedBusinessQuality: businessQuality == assessment.businessQuality ? nil : businessQuality,
                correctedPhotoRole: photoRole == assessment.photoRole ? nil : photoRole,
                correctedHairlinePresentation: hairlinePresentation == assessment.hairlinePresentation ? nil : hairlinePresentation,
                reviewedAt: .now
            )
            try await catalog.visualLearning.record(review)
            try await catalog.visualLearning.record(
                AssessmentFeedbackEvent(assessmentID: assessment.id, reviewID: review.id, outcome: .helpful, capturedAt: .now)
            )
            await refreshInspectorNow()
            statusMessage = "Recorded your corrected visual labels. Framebase did not organize this asset."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func recordBeforeAfterRelationship(beforeAssetID: AssetID, afterAssetID: AssetID, status: BeforeAfterRelationshipStatus) async {
        guard selectedAssetIDs == Set([beforeAssetID, afterAssetID]), let catalog = container.catalogDatabase else { return }
        do {
            try await catalog.visualLearning.store(
                BeforeAfterRelationship(beforeAssetID: beforeAssetID, afterAssetID: afterAssetID, status: status, createdAt: .now)
            )
            await refreshInspectorNow()
            statusMessage = "Recorded the before/after review. Framebase did not organize either asset."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Previews a safe organization workflow without changing a tag, folder,
    /// album, rating, favorite, Trash state, or managed original.
    func prepareTagWorkflow(named rawTagName: String) async {
        guard !selectedAssetIDs.isEmpty else { return }
        guard !container.cloudBackingIsActive, let catalog = container.catalogDatabase else {
            statusMessage = "Workflow application is unavailable while cloud synchronization is active."
            return
        }
        do {
            let tagName = try TagName(rawTagName)
            let snapshot = try await catalog.workflowInputSnapshot(assetIDs: selectedAssetIDs)
            let definition = try WorkflowDefinition(
                name: "Apply \(tagName.rawValue)",
                trigger: .manualSelection,
                actions: [.proposeTag(tagName.rawValue)]
            )
            let plan = try WorkflowPlanner().plan(definition: definition, snapshot: snapshot)
            try await catalog.workflows.store(definition, at: .now)
            let run = try await catalog.workflows.enqueue(plan: plan, actor: .human, at: .now)
            workflowTagPreview = WorkflowTagPreview(workflowRunID: run.id, plan: plan, tagName: tagName)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func approveAndApplyWorkflowTagPreview() async {
        guard let preview = workflowTagPreview, let catalog = container.catalogDatabase else { return }
        do {
            let currentSnapshot = try await catalog.workflowInputSnapshot(assetIDs: Set(preview.plan.snapshot.assetIDs))
            _ = try await catalog.workflows.approve(
                workflowRunID: preview.workflowRunID,
                currentSnapshot: currentSnapshot,
                actor: .human,
                at: .now
            )
            _ = try await catalog.workflows.executeApproved(
                workflowRunID: preview.workflowRunID,
                currentSnapshot: currentSnapshot,
                actor: .human,
                at: .now
            )
            workflowTagPreview = nil
            await refreshInspectorNow()
            statusMessage = "Applied \(preview.tagName.rawValue) to \(preview.plan.snapshot.assetIDs.count) selected asset\(preview.plan.snapshot.assetIDs.count == 1 ? "" : "s") after reviewing the exact plan."
        } catch {
            workflowTagPreview = nil
            statusMessage = error.localizedDescription
        }
    }

    func dismissWorkflowTagPreview() {
        workflowTagPreview = nil
    }

    func libraryStateDidChange() {
        folderObservationTask?.cancel()
        albumObservationTask?.cancel()
        tagObservationTask?.cancel()
        folderObservationTask = nil
        albumObservationTask = nil
        tagObservationTask = nil

        guard case .ready = container.libraryState,
              let folderRepository = container.folderRepository,
              let albumRepository = container.albumRepository else {
            folderTreeSnapshot = nil
            albums = []
            tags = []
            savedSearches = []
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

        if let tagRepository = container.tagRepository {
            tagObservationTask = Task { [weak self] in
                do {
                    for try await observedTags in tagRepository.observeTags() {
                        guard let self, !Task.isCancelled else { return }
                        tags = observedTags
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.statusMessage = error.localizedDescription
                }
            }
        }
        if let savedSearchRepository = container.savedSearchRepository {
            Task { [weak self] in
                let searches = (try? await savedSearchRepository.savedSearches()) ?? []
                guard let self, !Task.isCancelled else { return }
                savedSearches = searches
            }
        }
    }

    func createFolder(in parentFolderID: FolderID?) async {
        guard let repository = container.folderRepository else { return }
        do {
            let name = try nextAvailableFolderName(in: parentFolderID)
            let folder = try await repository.createFolder(named: name, in: parentFolderID)
            try await container.queueCloudFolderMutation(.create(folder))
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
            guard let updated = try await repository.treeSnapshot().folders.first(where: { $0.id == folderID }) else {
                throw FolderHistoryError.folderUnavailable
            }
            try await container.queueCloudFolderMutation(.rename(updated))
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
            guard let updated = try await repository.treeSnapshot().folders.first(where: { $0.id == folderID }) else {
                throw FolderHistoryError.folderUnavailable
            }
            try await container.queueCloudFolderMutation(.move(updated))
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
        guard !container.cloudBackingIsActive else {
            statusMessage = "Folder deletion is unavailable while cloud backing is active."
            return
        }
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
        guard !container.cloudBackingIsActive else {
            statusMessage = "Folder deletion is unavailable while cloud backing is active."
            pendingFolderDeletion = nil
            return
        }
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

    private func scheduleInspectorRefresh() {
        inspectorTask?.cancel()
        inspectorPreviewTask?.cancel()
        if let requestID = inspectorPreviewRequestID {
            Task { await container.thumbnailProvider?.cancel(requestID: requestID) }
        }
        inspectorPreviewRequestID = nil
        selectedAssets = []
        selectedAnalysisResults = []
        selectedPhotoAssessments = []
        selectedAssessmentReviews = [:]
        selectedBeforeAfterRelationships = []
        selectedTags = []
        selectedDuplicateCandidate = nil
        selectedTrashReceipts = []
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
            if let tagRepository = container.tagRepository {
                let tagsByAsset = try await tagRepository.tags(for: selection)
                let allTagSets = selection.map { Set(tagsByAsset[$0, default: []]) }
                selectedTags = allTagSets.dropFirst().reduce(allTagSets.first ?? []) { $0.intersection($1) }
                    .sorted { $0.name.rawValue < $1.name.rawValue }
            } else {
                selectedTags = []
            }
            if assets.count == 1, let asset = assets.first {
                requestInspectorPreview(for: asset)
                if let catalog = container.catalogDatabase {
                    let candidates = try await catalog.cloud.duplicateCandidates()
                    selectedDuplicateCandidate = candidates.first { $0.assetIDs.contains(asset.id) }
                    selectedAnalysisResults = try await catalog.intelligence.results(for: asset.id)
                    selectedPhotoAssessments = try await catalog.visualLearning.assessments(for: asset.id)
                    selectedAssessmentReviews = try await withThrowingTaskGroup(of: (UUID, [AssessmentReview]).self) { group in
                        for assessment in selectedPhotoAssessments {
                            group.addTask {
                                (assessment.id, try await catalog.visualLearning.reviews(for: assessment.id))
                            }
                        }
                        var results: [UUID: [AssessmentReview]] = [:]
                        for try await (assessmentID, reviews) in group {
                            results[assessmentID] = reviews
                        }
                        return results
                    }
                    selectedBeforeAfterRelationships = try await catalog.visualLearning.relationships(for: asset.id)
                }
            } else {
                inspectorPreviewState = nil
                selectedDuplicateCandidate = nil
                selectedAnalysisResults = []
                selectedPhotoAssessments = []
                selectedAssessmentReviews = [:]
                selectedBeforeAfterRelationships = []
            }
            selectedTrashReceipts = try await repository.trashReceipts(for: selection)
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
        let names = Set(albums.map { $0.name.lowercased() })
        var candidate = "New Album"
        var suffix = 2
        while names.contains(candidate.lowercased()) {
            candidate = "New Album \(suffix)"
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
