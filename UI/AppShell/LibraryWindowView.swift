import FramebaseDomain
import Foundation
import SwiftUI

struct LibraryWindowView: View {
    @State private var model: LibraryWindowModel
    @SceneStorage("library.inspectorVisible") private var storedInspectorVisible = true
    @SceneStorage("library.expandedFoldersByCatalog") private var storedExpandedFoldersByCatalog = ""
    @AppStorage("browser.thumbnailSize") private var storedThumbnailSize = 176.0

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
                }
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            FoundationAssetBrowser(model: model)
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
        .focusedValue(\.libraryCommandActions, commandActions)
        .onAppear {
            model.isInspectorVisible = storedInspectorVisible
            model.thumbnailSize = storedThumbnailSize
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
}
