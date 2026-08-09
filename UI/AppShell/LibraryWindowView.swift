import FramebaseDomain
import Foundation
import SwiftUI

struct LibraryWindowView: View {
    @State private var model: LibraryWindowModel
    @SceneStorage("library.inspectorVisible") private var storedInspectorVisible = true
    @SceneStorage("library.expandedFoldersByCatalog") private var storedExpandedFoldersByCatalog = ""
    @AppStorage("browser.thumbnailSize") private var storedThumbnailSize = 176.0
    @AppStorage("browser.presentation") private var storedBrowserPresentation = AssetBrowserPresentation.grid.rawValue
    @State private var isSearchFilterPopoverPresented = false
    @State private var isDuplicateReviewPresented = false

    init(container: AppContainer) {
        _model = State(initialValue: LibraryWindowModel(container: container))
    }

    var body: some View {
        NavigationSplitView {
            FoundationSidebar(
                folderTree: model.folderTreeSnapshot,
                albums: model.albums,
                tags: model.tags,
                savedSearches: model.savedSearches,
                smartCollections: model.smartCollections,
                selection: navigationBinding,
                expandedFolderIDs: expandedFolderIDsBinding,
                isKeyboardFocused: sidebarKeyboardFocusBinding,
                focusRequestGeneration: model.sidebarFocusRequestGeneration,
                onRenameFolder: { folderID, proposedName in
                    Task {
                        await model.renameFolder(folderID, to: proposedName)
                    }
                },
                onRenameAlbum: { albumID, proposedName in
                    Task {
                        await model.renameAlbum(albumID, to: proposedName)
                    }
                },
                onRenameTag: { tagID, proposedName in
                    Task {
                        await model.renameTag(tagID, to: proposedName)
                    }
                },
                onRenameSavedSearch: { savedSearchID, proposedName in
                    Task {
                        await model.renameSavedSearch(savedSearchID, to: proposedName)
                    }
                },
                onRenameSmartCollection: { smartCollectionID, proposedName in
                    Task {
                        await model.renameSmartCollection(smartCollectionID, to: proposedName)
                    }
                },
                onContextAction: handleSidebarContextAction,
                validateFolderDrop: { drop in
                    model.canReparentFolder(drop.sourceFolderID, to: drop.destinationParentFolderID)
                        ? .allowed
                        : .rejected
                },
                onReparentFolder: { drop in
                    Task {
                        await model.reparentFolder(drop.sourceFolderID, to: drop.destinationParentFolderID)
                    }
                },
                validateAssetDrop: { drop in
                    model.canMoveAssets(drop.assetIDs, to: drop.destinationFolderID)
                        ? .allowed
                        : .rejected
                },
                onMoveAssets: { drop in
                    Task {
                        await model.moveAssets(drop.assetIDs, to: drop.destinationFolderID)
                    }
                }
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            FoundationAssetBrowser(model: model)
                .dropDestination(for: URL.self) { urls, _ in
                    guard model.container.canBrowseLibrary, !urls.isEmpty else { return false }
                    Task {
                        await model.importAssets(from: urls)
                    }
                    return true
                }
                .inspector(isPresented: inspectorBinding) {
                    FoundationInspector(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.requestImport()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.container.canBrowseLibrary)

                Button(role: .destructive) {
                    Task { await model.moveSelectedAssetsToTrash() }
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(model.selectedAssetIDs.isEmpty || model.navigationTarget == .trash)
                .accessibilityIdentifier("toolbar.moveToTrash")

                Button {
                    guard let destinationURL = LibraryPanelService.chooseExportDirectory() else { return }
                    Task { await model.exportSelectedAssets(to: destinationURL) }
                } label: {
                    Label("Export Originals", systemImage: "square.and.arrow.up")
                }
                .disabled(model.selectedAssetIDs.isEmpty)

                Menu {
                    ForEach(model.moveDestinationFolders) { folder in
                        Button(folder.name.rawValue) {
                            Task { await model.moveAssets(model.selectedAssetIDs, to: folder.id) }
                        }
                        .disabled(!model.canMoveAssets(model.selectedAssetIDs, to: folder.id))
                    }
                } label: {
                    Label("Move To", systemImage: "folder.badge.arrow.forward")
                }
                .disabled(model.selectedAssetIDs.isEmpty || model.moveDestinationFolders.isEmpty)

                Button {
                    model.revealSelectedOriginals()
                } label: {
                    Label("Reveal Originals", systemImage: "folder")
                }
                .disabled(model.selectedAssetIDs.isEmpty)

                Button {
                    isDuplicateReviewPresented = true
                    Task { await model.refreshDuplicateCandidates() }
                } label: {
                    Label("Review Duplicates", systemImage: "rectangle.on.rectangle")
                }
                .popover(isPresented: $isDuplicateReviewPresented) {
                    DuplicateCandidatesPopover(candidates: model.duplicateCandidates)
                }

                if model.navigationTarget == .trash {
                    Button {
                        Task { await model.restoreSelectedAssetsFromTrash() }
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.selectedAssetIDs.isEmpty)
                    .accessibilityIdentifier("toolbar.restoreFromTrash")
                }

                Menu {
                    ForEach(AssetSort.Key.allCases, id: \.self) { key in
                        Button(sortLabel(for: key)) {
                            model.assetSort = AssetSort(key: key, direction: model.assetSort.direction)
                        }
                    }

                    Divider()

                    Picker("Direction", selection: sortDirectionBinding) {
                        Text("Ascending").tag(AssetSort.Direction.ascending)
                        Text("Descending").tag(AssetSort.Direction.descending)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }

                Menu {
                    Button("Save Current Search") {
                        Task { await model.saveCurrentSearch() }
                    }

                    if !model.savedSearches.isEmpty {
                        Divider()
                        ForEach(model.savedSearches) { savedSearch in
                            Menu(savedSearch.name) {
                                Button("Apply") { model.applySavedSearch(savedSearch) }
                                Button("Delete", role: .destructive) {
                                    Task { await model.deleteSavedSearch(savedSearch.id) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Saved Searches", systemImage: "bookmark")
                }
                .accessibilityIdentifier("toolbar.savedSearches")

                Menu {
                    Button("Create From Current Rules") {
                        Task { await model.createSmartCollectionFromCurrentQuery() }
                    }

                    if !model.smartCollections.isEmpty {
                        Divider()
                        ForEach(model.smartCollections) { smartCollection in
                            Menu(smartCollection.name) {
                                Button("Apply") { model.applySmartCollection(smartCollection) }
                                Button("Delete", role: .destructive) {
                                    Task { await model.deleteSmartCollection(smartCollection.id) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Smart Collections", systemImage: "sparkles")
                }
                .accessibilityIdentifier("toolbar.smartCollections")

                Button {
                    isSearchFilterPopoverPresented.toggle()
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("toolbar.searchFilters")
                .popover(isPresented: $isSearchFilterPopoverPresented) {
                    SearchFiltersPopover(
                        criteria: model.assetQuery.criteria,
                        tags: model.tags,
                        albums: model.albums,
                        onChange: model.updateSearchCriteria
                    )
                }

                Picker("View", selection: browserPresentationBinding) {
                    ForEach(AssetBrowserPresentation.allCases) { presentation in
                        Label(presentation.title, systemImage: presentation.systemImage)
                            .tag(presentation)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 104)
                .accessibilityIdentifier("assetBrowser.presentation")

                Slider(value: thumbnailSizeBinding, in: 96...280, step: 8) {
                    Text("Thumbnail Size")
                } minimumValueLabel: {
                    Image(systemName: "photo")
                } maximumValueLabel: {
                    Image(systemName: "photo.fill")
                }
                .frame(width: 170)

                Button {
                    inspectorBinding.wrappedValue.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .focusedSceneValue(\.libraryCommandActions, commandActions)
        .searchable(text: searchTextBinding, prompt: "Search Library")
        .onAppear {
            model.isInspectorVisible = storedInspectorVisible
            model.thumbnailSize = storedThumbnailSize
            model.browserPresentation = AssetBrowserPresentation(rawValue: storedBrowserPresentation) ?? .grid
        }
        .task {
            await model.container.restoreLibraryIfAvailable()
        }
        .task(id: model.container.libraryState) {
            model.libraryStateDidChange()
            restoreExpansionStateIfAvailable()
        }
        .onChange(of: model.expandedFolderIDs) {
            persistExpansionState()
        }
        .onChange(of: model.importRequestGeneration) {
            let urls = LibraryPanelService.chooseImagesForImport()
            guard !urls.isEmpty else { return }
            Task {
                await model.importAssets(from: urls)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isImporting, let progress = model.importProgress {
                importProgressView(progress)
            }
        }
        .confirmationDialog(
            "Delete Folder?",
            isPresented: deletionPromptBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                guard let prompt = model.pendingFolderDeletion else { return }
                model.cancelPendingFolderDeletion()
                Task {
                    await model.deleteFolder(prompt)
                }
            }
            Button("Cancel", role: .cancel) {
                model.cancelPendingFolderDeletion()
            }
        } message: {
            if let prompt = model.pendingFolderDeletion {
                Text(deletionMessage(for: prompt))
            }
        }
        .alert("Framebase Couldn’t Complete That Action", isPresented: statusMessageBinding) {
            Button("OK") {
                model.statusMessage = nil
            }
        } message: {
            Text(model.statusMessage ?? "Unknown error")
        }
    }

    private var navigationBinding: Binding<NavigationTarget?> {
        Binding(
            get: { model.navigationTarget },
            set: { target in
                if let target {
                    model.navigationTarget = target
                }
            }
        )
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { model.isInspectorVisible },
            set: { newValue in
                model.isInspectorVisible = newValue
                storedInspectorVisible = newValue
            }
        )
    }

    private var expandedFolderIDsBinding: Binding<Set<FolderID>> {
        Binding(
            get: { model.expandedFolderIDs },
            set: { model.expandedFolderIDs = $0 }
        )
    }

    private var sidebarKeyboardFocusBinding: Binding<Bool> {
        Binding(
            get: { model.isSidebarKeyboardFocused },
            set: { model.isSidebarKeyboardFocused = $0 }
        )
    }

    private var thumbnailSizeBinding: Binding<Double> {
        Binding(
            get: { model.thumbnailSize },
            set: { newValue in
                model.thumbnailSize = newValue
                storedThumbnailSize = newValue
            }
        )
    }

    private var browserPresentationBinding: Binding<AssetBrowserPresentation> {
        Binding(
            get: { model.browserPresentation },
            set: { presentation in
                model.browserPresentation = presentation
                storedBrowserPresentation = presentation.rawValue
            }
        )
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { model.searchText },
            set: { model.searchText = $0 }
        )
    }

    private var deletionPromptBinding: Binding<Bool> {
        Binding(
            get: { model.pendingFolderDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelPendingFolderDeletion()
                }
            }
        )
    }

    private var statusMessageBinding: Binding<Bool> {
        Binding(
            get: { model.statusMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.statusMessage = nil
                }
            }
        )
    }

    private var sortDirectionBinding: Binding<AssetSort.Direction> {
        Binding(
            get: { model.assetSort.direction },
            set: { model.assetSort.direction = $0 }
        )
    }

    private var commandActions: LibraryCommandActions {
        return LibraryCommandActions(
            importAssets: { model.requestImport() },
            createFolder: {
                Task {
                    await model.createFolder(in: nil)
                }
            },
            createSubfolder: {
                guard let folderID = selectedFolderID else { return }
                Task {
                    await model.createFolder(in: folderID)
                }
            },
            createAlbum: { Task { await model.createAlbum() } },
            createTag: { Task { await model.createTag() } },
            undo: { Task { await model.undoLastAction() } },
            redo: { Task { await model.redoLastAction() } },
            selectAll: { model.selectAllVisibleAssets() },
            toggleInspector: { inspectorBinding.wrappedValue.toggle() },
            canImport: model.container.canBrowseLibrary,
            canCreateFolder: model.container.canBrowseLibrary,
            canCreateSubfolder: model.container.canBrowseLibrary && selectedFolderID != nil,
            canCreateAlbum: model.container.canBrowseLibrary,
            canCreateTag: model.container.canBrowseLibrary,
            canUndo: model.canUndoAction,
            canRedo: model.canRedoAction,
            canSelectAll: !model.orderedVisibleAssetIDs.isEmpty
        )
    }

    private var selectedFolderID: FolderID? {
        if case let .folder(folderID) = model.navigationTarget {
            return folderID
        }
        return nil
    }

    private func sortLabel(for key: AssetSort.Key) -> String {
        switch key {
        case .displayName: "Name"
        case .importedAt: "Date Imported"
        case .modifiedAt: "Date Modified"
        case .createdAt: "Date Created"
        case .fileSize: "File Size"
        case .rating: "Rating"
        }
    }

    private func handleSidebarContextAction(_ action: SidebarContextAction) {
        switch action {
        case let .createFolder(parentFolderID):
            Task {
                await model.createFolder(in: parentFolderID)
            }
        case let .deleteFolder(folderID):
            Task {
                await model.prepareToDeleteFolder(folderID)
            }
        case .createAlbum:
            Task { await model.createAlbum() }
        case let .deleteAlbum(albumID):
            Task { await model.deleteAlbum(albumID) }
        case let .moveAlbum(albumID, earlier):
            Task { await model.moveAlbum(albumID, earlier: earlier) }
        case .createTag:
            Task { await model.createTag() }
        case let .deleteTag(tagID):
            Task { await model.deleteTag(tagID) }
        case let .deleteSavedSearch(savedSearchID):
            Task { await model.deleteSavedSearch(savedSearchID) }
        case let .deleteSmartCollection(smartCollectionID):
            Task { await model.deleteSmartCollection(smartCollectionID) }
        }
    }

    private func restoreExpansionStateIfAvailable() {
        guard case let .ready(catalogID) = model.container.libraryState,
              let data = storedExpandedFoldersByCatalog.data(using: .utf8),
              let stored = try? JSONDecoder().decode([String: [FolderID]].self, from: data) else {
            return
        }
        model.expandedFolderIDs = Set(stored[catalogID.description, default: []])
    }

    private func persistExpansionState() {
        guard case let .ready(catalogID) = model.container.libraryState else { return }
        var stored: [String: [FolderID]] = [:]
        if let data = storedExpandedFoldersByCatalog.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: [FolderID]].self, from: data) {
            stored = decoded
        }
        stored[catalogID.description] = model.expandedFolderIDs.sorted {
            $0.description < $1.description
        }
        guard let data = try? JSONEncoder().encode(stored),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        storedExpandedFoldersByCatalog = encoded
    }

    private func deletionMessage(for prompt: FolderDeletionPrompt) -> String {
        let folderDescription = prompt.folderCount == 1
            ? "this folder"
            : "this folder and \(prompt.folderCount - 1) subfolder(s)"
        let assetDescription = prompt.assetCount == 1 ? "1 asset" : "\(prompt.assetCount) assets"
        return "Delete \(folderDescription) beginning with “\(prompt.folderName)”? \(assetDescription) will move to Inbox. Original files will not be deleted."
    }

    private func importProgressView(_ progress: ImportProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView(
                value: Double(progress.completedCount),
                total: Double(max(progress.totalCount, 1))
            )
            .frame(maxWidth: 280)

            Text(progress.currentFilename ?? "Importing images…")
                .lineLimit(1)
            Text("\(progress.completedCount) of \(progress.totalCount)")
                .foregroundStyle(.secondary)

            Button("Cancel") {
                Task { await model.cancelImport() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityIdentifier("import.progress")
    }
}

private struct DuplicateCandidatesPopover: View {
    let candidates: [DuplicateCandidate]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duplicate Candidates")
                .font(.headline)
            Text("Suggestions based only on matching SHA-256 checksums. No files will be merged, deleted, or changed here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                ContentUnavailableView("No checksum matches", systemImage: "checkmark.circle")
            } else {
                List(candidates, id: \.sha256) { candidate in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(candidate.assetIDs.count) matching originals")
                        Text(candidate.sha256)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
