import FramebaseDomain
import SwiftUI

struct LibraryWindowView: View {
    @State private var model: LibraryWindowModel
    @SceneStorage("library.inspectorVisible") private var storedInspectorVisible = true
    @AppStorage("browser.thumbnailSize") private var storedThumbnailSize = 176.0

    init(container: AppContainer) {
        _model = State(initialValue: LibraryWindowModel(container: container))
    }

    var body: some View {
        NavigationSplitView {
            FoundationSidebar(selection: navigationBinding)
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

    private var thumbnailSizeBinding: Binding<Double> {
        Binding(
            get: { model.thumbnailSize },
            set: { newValue in
                model.thumbnailSize = newValue
                storedThumbnailSize = newValue
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
        LibraryCommandActions(
            importAssets: { model.requestImport() },
            selectAll: { model.selectAllVisibleAssets() },
            toggleInspector: { inspectorBinding.wrappedValue.toggle() },
            canImport: model.container.canBrowseLibrary,
            canSelectAll: !model.orderedVisibleAssetIDs.isEmpty
        )
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
}
