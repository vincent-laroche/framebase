import FramebaseDomain
import Foundation
import SwiftUI

struct LibraryWindowView: View {
    @State private var model: LibraryWindowModel
    @SceneStorage("library.inspectorVisible") private var storedInspectorVisible = true
    @SceneStorage("library.expandedFoldersByCatalog") private var storedExpandedFoldersByCatalog = ""
    @AppStorage("browser.thumbnailSize") private var storedThumbnailSize = 176.0
    @SceneStorage("library.browserPresentation") private var storedBrowserPresentation = AssetBrowserPresentation.grid.rawValue
    @State private var isSaveSearchPresented = false

    init(container: AppContainer) {
        _model = State(initialValue: LibraryWindowModel(container: container))
    }

    var body: some View {
        NavigationSplitView {
            FoundationSidebar(
                folderTree: model.folderTreeSnapshot,
                albums: model.albums,
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
                .searchable(text: searchTextBinding, placement: .toolbar, prompt: "Search names, camera, folders, tags…")
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
                    Button("Clear Filters", action: model.clearAssetFilters)
                    Divider()
                    Menu("Tags") {
                        ForEach(model.tags) { tag in
                            Button {
                                model.toggleTagFilter(tag.id)
                            } label: {
                                Label(
                                    tag.name.rawValue,
                                    systemImage: model.assetFilter.tagIDs.contains(tag.id) ? "checkmark" : "tag"
                                )
                            }
                        }
                    }
                    Menu("Favorite") {
                        Button("Any") { model.setFavoriteFilter(nil) }
                        Button("Favorites Only") { model.setFavoriteFilter(true) }
                        Button("Not Favorites") { model.setFavoriteFilter(false) }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }

                Menu {
                    Button("Save Current Search…") { isSaveSearchPresented = true }
                    if !model.savedSearches.isEmpty {
                        Divider()
                        ForEach(model.savedSearches) { savedSearch in
                            Menu(savedSearch.name.rawValue) {
                                Button("Apply") { model.applySavedSearch(savedSearch) }
                                Button("Delete", role: .destructive) {
                                    Task { await model.deleteSavedSearch(savedSearch.id) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Saved Searches", systemImage: "magnifyingglass.circle")
                }
                .disabled(!model.container.canBrowseLibrary)

                Picker("View", selection: browserPresentationBinding) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(AssetBrowserPresentation.grid)
                    Label("List", systemImage: "list.bullet").tag(AssetBrowserPresentation.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 108)

                Menu {
                    Button("New Album") { Task { await model.createAlbum() } }
                    if !model.selectedAssetIDs.isEmpty, !model.albums.isEmpty {
                        Divider()
                        ForEach(model.albums) { album in
                            Button("Add Selection to \(album.name)") {
                                Task { await model.addSelectedAssets(to: album.id) }
                            }
                        }
                    }
                } label: {
                    Label("Albums", systemImage: "rectangle.stack.badge.plus")
                }
                .accessibilityIdentifier("toolbar.albums")
                .disabled(!model.container.canBrowseLibrary)

                Button {
                    Task {
                        if model.navigationTarget == .trash {
                            await model.restoreSelectedAssets()
                        } else {
                            await model.trashSelectedAssets()
                        }
                    }
                } label: {
                    Label(
                        model.navigationTarget == .trash ? "Restore" : "Move to Trash",
                        systemImage: model.navigationTarget == .trash ? "arrow.uturn.backward" : "trash"
                    )
                }
                .accessibilityIdentifier("toolbar.trashOrRestore")
                .disabled(model.selectedAssetIDs.isEmpty)

                Menu {
                    Button("Apply Hair Solutions Template") {
                        Task { await model.prepareHairSolutionsTemplateApplication() }
                    }
                } label: {
                    Label("Library", systemImage: "folder.badge.gearshape")
                }
                .disabled(!model.container.canBrowseLibrary || model.container.cloudBackingIsActive)

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
        .onChange(of: model.browserPresentation) {
            storedBrowserPresentation = model.browserPresentation.rawValue
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
        .sheet(item: hairSolutionsTemplatePreviewBinding) { preview in
            HairSolutionsTemplateReviewSheet(
                preview: preview,
                apply: {
                    Task { await model.applyHairSolutionsTemplate() }
                },
                cancel: model.dismissHairSolutionsTemplatePreview
            )
        }
        .sheet(isPresented: $isSaveSearchPresented) {
            SavedSearchSheet(
                save: { name in
                    Task { await model.saveCurrentSearch(named: name) }
                    isSaveSearchPresented = false
                },
                cancel: { isSaveSearchPresented = false }
            )
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

    private var searchTextBinding: Binding<String> {
        Binding(get: { model.searchText }, set: { model.searchText = $0 })
    }

    private var browserPresentationBinding: Binding<AssetBrowserPresentation> {
        Binding(get: { model.browserPresentation }, set: { model.browserPresentation = $0 })
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

    private var hairSolutionsTemplatePreviewBinding: Binding<LibraryTemplateApplicationPreview?> {
        Binding(
            get: { model.hairSolutionsTemplatePreview },
            set: { preview in
                if preview == nil {
                    model.dismissHairSolutionsTemplatePreview()
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
            undo: { Task { await model.undoLastAction() } },
            redo: { Task { await model.redoLastAction() } },
            selectAll: { model.selectAllVisibleAssets() },
            toggleInspector: { inspectorBinding.wrappedValue.toggle() },
            canImport: model.container.canBrowseLibrary,
            canCreateFolder: model.container.canBrowseLibrary,
            canCreateSubfolder: model.container.canBrowseLibrary && selectedFolderID != nil,
            canUndo: model.canUndoFolderAction,
            canRedo: model.canRedoFolderAction,
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

private struct HairSolutionsTemplateReviewSheet: View {
    let preview: LibraryTemplateApplicationPreview
    let apply: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apply Hair Solutions Template")
                .font(.title2.weight(.semibold))
            Text(summary)
                .foregroundStyle(.secondary)

            GroupBox("Folders to create (\(preview.folderPathsToCreate.count))") {
                reviewList(preview.folderPathsToCreate)
            }
            GroupBox("Controlled tags to create (\(preview.tagNamesToCreate.count))") {
                reviewList(preview.tagNamesToCreate.map(\.rawValue))
            }
            Text("\(preview.onFirstUseFolderPaths.count) on-first-use folders remain available vocabulary and will not be created. Existing folders and tags are left unchanged. No assets or original files will move.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Apply Template", action: apply)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 620, height: 620)
    }

    private var summary: String {
        if preview.folderPathsToCreate.isEmpty && preview.tagNamesToCreate.isEmpty {
            return "This library already has every initial folder and controlled tag in the template."
        }
        return "Review the exact logical catalog additions below before applying them."
    }

    @ViewBuilder
    private func reviewList(_ items: [String]) -> some View {
        if items.isEmpty {
            Text("Nothing new")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }
}

private struct SavedSearchSheet: View {
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Search")
                .font(.title2.weight(.semibold))
            Text("Save the current text, tag, favorite, date, rating, and album filters with the selected sort order.")
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .onSubmit(saveSearch)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save", action: saveSearch)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func saveSearch() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        save(name)
    }
}
