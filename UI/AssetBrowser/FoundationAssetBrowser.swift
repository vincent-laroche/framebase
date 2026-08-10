import AppKit
import FramebaseDomain
import SwiftUI

struct FoundationAssetBrowser: View {
    let model: LibraryWindowModel

    var body: some View {
        Group {
            switch model.container.libraryState {
            case .notConfigured, .failed:
                LibrarySetupView(container: model.container)
            case .opening:
                ProgressView("Opening Framebase Library…")
                    .controlSize(.large)
            case .ready:
                if model.orderedVisibleAssetIDs.isEmpty {
                    ContentUnavailableView {
                        Label(model.navigationTitle, systemImage: "photo.stack")
                    } description: {
                        Text("No assets match this destination.")
                    }
                    .accessibilityIdentifier("assetBrowser.empty.\(model.navigationTarget.title)")
                } else {
                    if model.browserPresentation == .grid {
                        NativeAssetCollection(
                            records: model.assetGridRecords,
                            thumbnailStates: model.thumbnailStates,
                            selectedAssetIDs: model.selectedAssetIDs,
                            thumbnailSize: model.thumbnailSize,
                            onSelectionChanged: { ids, anchorID in
                                model.selectedAssetIDs = ids
                                model.selectionAnchorID = anchorID
                                model.keyboardFocusedAssetID = anchorID
                            },
                            onRequestThumbnail: { record, scale in
                                model.requestThumbnail(for: record, displayScale: scale)
                            },
                            onCancelThumbnail: model.cancelThumbnail,
                            onNearEnd: model.loadNextAssetPageIfNeeded,
                            onSelectAll: model.selectAllVisibleAssets
                        )
                        .accessibilityIdentifier("assetBrowser.grid")
                    } else {
                        AssetMetadataList(
                            records: model.assetGridRecords,
                            selectedAssetIDs: listSelectionBinding,
                            sort: model.assetSort,
                            setSort: { model.assetSort = $0 }
                        )
                        .accessibilityIdentifier("assetBrowser.list")
                    }
                }
            }
        }
        .navigationTitle(model.navigationTitle)
    }

    private var listSelectionBinding: Binding<Set<AssetID>> {
        Binding(
            get: { model.selectedAssetIDs },
            set: { ids in
                model.selectedAssetIDs = ids
                model.selectionAnchorID = ids.count == 1 ? ids.first : nil
                model.keyboardFocusedAssetID = model.selectionAnchorID
            }
        )
    }
}

private struct AssetMetadataList: View {
    let records: [AssetGridRecord]
    @Binding var selectedAssetIDs: Set<AssetID>
    let sort: AssetSort
    let setSort: (AssetSort) -> Void

    var body: some View {
        Table(records, selection: $selectedAssetIDs) {
            TableColumn("Name") { record in
                HStack(spacing: 6) {
                    Image(systemName: record.originalAvailable ? "photo" : "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                    Text(record.displayName)
                }
            }
            TableColumn("Modified") { record in
                Text(record.modifiedAt, format: .dateTime.year().month().day().hour().minute())
            }
            TableColumn("Dimensions") { record in
                Text(dimensions(record))
            }
            TableColumn("Size") { record in
                Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
            }
            TableColumn("Rating") { record in
                Text(record.rating.rawValue == 0 ? "—" : "\(record.rating.rawValue) ★")
            }
        }
        .contextMenu {
            Menu("Sort") {
                Button("Name") { setSort(AssetSort(key: .displayName, direction: sort.direction)) }
                Button("Modified") { setSort(AssetSort(key: .modifiedAt, direction: sort.direction)) }
                Button("Size") { setSort(AssetSort(key: .fileSize, direction: sort.direction)) }
                Button("Rating") { setSort(AssetSort(key: .rating, direction: sort.direction)) }
            }
        }
    }

    private func dimensions(_ record: AssetGridRecord) -> String {
        guard let width = record.width, let height = record.height else { return "—" }
        return "\(width) × \(height)"
    }
}

@MainActor
enum AssetDragSessionRegistry {
    private static var sessions: [UUID: Set<AssetID>] = [:]

    static func create(assetIDs: Set<AssetID>) -> UUID {
        let token = UUID()
        sessions[token] = assetIDs
        return token
    }

    static func assetIDs(for token: UUID) -> Set<AssetID>? {
        sessions[token]
    }

    static func remove(_ token: UUID) {
        sessions.removeValue(forKey: token)
    }
}

extension NSPasteboard.PasteboardType {
    static let framebaseAssets = Self("com.vincentlaroche.framebase.assets")
}

private struct NativeAssetCollection: NSViewControllerRepresentable {
    let records: [AssetGridRecord]
    let thumbnailStates: [AssetID: AssetThumbnailState]
    let selectedAssetIDs: Set<AssetID>
    let thumbnailSize: Double
    let onSelectionChanged: (Set<AssetID>, AssetID?) -> Void
    let onRequestThumbnail: (AssetGridRecord, Double) -> Void
    let onCancelThumbnail: (AssetID) -> Void
    let onNearEnd: (Int) -> Void
    let onSelectAll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSViewController(context: Context) -> AssetCollectionViewController {
        let controller = AssetCollectionViewController()
        // The controller registers the item class immediately after assigning
        // its layout, and assigning a layout discards earlier registrations.
        // Loading the view here keeps that ordering deterministic.
        controller.loadViewIfNeeded()
        let collectionView = controller.collectionView
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.registerForDraggedTypes([.framebaseAssets])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.onSelectAll = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSelectAll()
        }
        context.coordinator.collectionView = collectionView
        context.coordinator.apply(parent: self, reloadAll: true)
        return controller
    }

    func updateNSViewController(_ controller: AssetCollectionViewController, context: Context) {
        let priorIDs = context.coordinator.parent.records.map(\.id)
        let reloadAll = priorIDs != records.map(\.id)
            || context.coordinator.parent.thumbnailSize != thumbnailSize
        context.coordinator.apply(parent: self, reloadAll: reloadAll)
    }

    @MainActor
    final class Coordinator: NSObject,
        NSCollectionViewDataSource,
        NSCollectionViewDelegate,
        NSCollectionViewPrefetching
    {
        var parent: NativeAssetCollection
        weak var collectionView: NSCollectionView?
        private var isSynchronizingSelection = false
        private var activeDragToken: UUID?

        init(parent: NativeAssetCollection) {
            self.parent = parent
        }

        func apply(parent: NativeAssetCollection, reloadAll: Bool) {
            self.parent = parent
            guard let collectionView else { return }
            if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
                let size = max(72, parent.thumbnailSize)
                let itemSize = NSSize(width: size, height: size + 28)
                // Invalidating on every update re-runs layout for unchanged
                // geometry, which is pure churn on a thumbnail-state update.
                if layout.itemSize != itemSize {
                    layout.itemSize = itemSize
                    layout.invalidateLayout()
                }
            }
            if reloadAll {
                collectionView.reloadData()
            } else {
                reconfigureVisibleItems(in: collectionView)
            }
            synchronizeSelection()
        }

        /// Reloading items tears cells down and displays them again, so it fires
        /// `didEndDisplaying` and `willDisplay` a second time. Those callbacks
        /// cancel and re-request thumbnails, and cancelling clears the in-flight
        /// `.loading` state, so every arriving state change queued another full
        /// reload: the browser spun at 100% CPU and no decode ever survived long
        /// enough to finish. Reconfiguring the cells that are already on screen
        /// applies the same state without touching the display lifecycle.
        private func reconfigureVisibleItems(in collectionView: NSCollectionView) {
            let imageSize = max(72, parent.thumbnailSize)
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard indexPath.item < parent.records.count,
                      let item = collectionView.item(at: indexPath) as? AssetCollectionItem else {
                    continue
                }
                let record = parent.records[indexPath.item]
                item.configure(
                    record: record,
                    state: parent.thumbnailStates[record.id],
                    imageSize: imageSize
                )
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            parent.records.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            guard indexPath.item < parent.records.count,
                  let item = collectionView.makeItem(
                    withIdentifier: .assetCollectionItem,
                    for: indexPath
                  ) as? AssetCollectionItem else {
                return NSCollectionViewItem()
            }
            let record = parent.records[indexPath.item]
            item.configure(
                record: record,
                state: parent.thumbnailStates[record.id],
                imageSize: max(72, parent.thumbnailSize)
            )
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard indexPath.item < parent.records.count else { return }
            let record = parent.records[indexPath.item]
            parent.onRequestThumbnail(
                record,
                Double(collectionView.window?.backingScaleFactor ?? 2)
            )
            parent.onNearEnd(indexPath.item)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard indexPath.item < parent.records.count else { return }
            parent.onCancelThumbnail(parent.records[indexPath.item].id)
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection(changedIndexPaths: indexPaths)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection(changedIndexPaths: indexPaths)
        }

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let scale = Double(collectionView.window?.backingScaleFactor ?? 2)
            for indexPath in indexPaths where indexPath.item < parent.records.count {
                parent.onRequestThumbnail(parent.records[indexPath.item], scale)
                parent.onNearEnd(indexPath.item)
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            for indexPath in indexPaths where indexPath.item < parent.records.count {
                parent.onCancelThumbnail(parent.records[indexPath.item].id)
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> (any NSPasteboardWriting)? {
            (collectionView as? AssetCollectionView)?.clearPendingCollapse()
            guard indexPath.item < parent.records.count else { return nil }
            let selectedIDs = assetIDs(for: collectionView.selectionIndexPaths)
            let draggedIDs = selectedIDs.isEmpty
                ? Set([parent.records[indexPath.item].id])
                : selectedIDs
            if activeDragToken == nil {
                activeDragToken = AssetDragSessionRegistry.create(assetIDs: draggedIDs)
            }
            guard let activeDragToken else { return nil }
            let item = NSPasteboardItem()
            item.setString(activeDragToken.uuidString, forType: .framebaseAssets)
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            dragOperation operation: NSDragOperation
        ) {
            if let activeDragToken {
                AssetDragSessionRegistry.remove(activeDragToken)
                self.activeDragToken = nil
            }
        }

        private func synchronizeSelection() {
            guard let collectionView else { return }
            let indexPaths = Set(parent.records.enumerated().compactMap { index, record in
                parent.selectedAssetIDs.contains(record.id)
                    ? IndexPath(item: index, section: 0)
                    : nil
            })
            guard collectionView.selectionIndexPaths != indexPaths else { return }
            isSynchronizingSelection = true
            collectionView.selectionIndexPaths = indexPaths
            isSynchronizingSelection = false
        }

        private func publishSelection(changedIndexPaths: Set<IndexPath>) {
            guard !isSynchronizingSelection, let collectionView else { return }
            let ids = assetIDs(for: collectionView.selectionIndexPaths)
            let anchorID = changedIndexPaths
                .sorted(by: { $0.item < $1.item })
                .last
                .flatMap { indexPath in
                    indexPath.item < parent.records.count ? parent.records[indexPath.item].id : nil
                }
            parent.onSelectionChanged(ids, anchorID ?? ids.first)
        }

        private func assetIDs(for indexPaths: Set<IndexPath>) -> Set<AssetID> {
            Set(indexPaths.compactMap { indexPath in
                indexPath.item < parent.records.count ? parent.records[indexPath.item].id : nil
            })
        }
    }
}

/// `NSCollectionView` answers `selectAll:` from the responder chain, so ⌘A
/// selects only the cells it has currently realized while the Assets ▸ Select
/// All menu item selects every asset in scope. Routing the responder action out
/// puts the shortcut and the menu item on one code path, so a paged folder
/// selects all of its assets rather than just the loaded page.
///
/// Note: ⌘A was also observed doing nothing at all against a large real folder.
/// That symptom is not reproduced by the UI suite and is not explained by this
/// change alone.
@MainActor
private final class AssetCollectionView: NSCollectionView {
    var onSelectAll: (() -> Void)?
    private var pendingCollapseIndexPath: IndexPath?

    override func selectAll(_ sender: Any?) {
        guard let onSelectAll else {
            super.selectAll(sender)
            return
        }
        onSelectAll()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.contains(.command),
           !flags.contains(.shift),
           let indexPath = indexPathForItem(at: point),
           selectionIndexPaths.contains(indexPath),
           selectionIndexPaths.count > 1 {
            pendingCollapseIndexPath = indexPath
        } else {
            pendingCollapseIndexPath = nil
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let indexPath = pendingCollapseIndexPath
        pendingCollapseIndexPath = nil
        super.mouseUp(with: event)
        if let indexPath, selectionIndexPaths.count > 1 {
            selectionIndexPaths = [indexPath]
            if let coordinator = delegate as? NativeAssetCollection.Coordinator {
                coordinator.collectionView(self, didSelectItemsAt: [indexPath])
            }
        }
    }

    func clearPendingCollapse() {
        pendingCollapseIndexPath = nil
    }
}

@MainActor
private final class AssetCollectionViewController: NSViewController {
    let collectionView = AssetCollectionView()

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18

        collectionView.collectionViewLayout = layout
        // Assigning the layout resets item-class registrations, so registering
        // any earlier leaves `makeItem` searching for a nib that does not
        // exist and raising an exception on the first dequeued cell.
        collectionView.register(
            AssetCollectionItem.self,
            forItemWithIdentifier: .assetCollectionItem
        )
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.focusRingType = .exterior

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView
        view = scrollView
    }
}

@MainActor
private final class AssetCollectionItem: NSCollectionViewItem {
    private let thumbnailView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let placeholderField = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 9

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        // An image view takes its intrinsic size from the image it holds. At
        // default priorities a full-size thumbnail outranks these constraints,
        // so the picture spilled past the cell background and pushed the
        // filename out of view: only cells whose image happened to be smaller
        // than the cell showed a label. Letting the layout win keeps every cell
        // the same shape regardless of what it is displaying.
        thumbnailView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        thumbnailView.setContentHuggingPriority(.defaultLow, for: .vertical)
        thumbnailView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        thumbnailView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 7
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleField.maximumNumberOfLines = 1
        // The filename keeps its line; long names truncate instead of forcing
        // the cell to grow.
        titleField.setContentCompressionResistancePriority(.required, for: .vertical)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.alignment = .center
        placeholderField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.maximumNumberOfLines = 2

        for subview in [thumbnailView, titleField, progressIndicator, placeholderField] {
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            titleField.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
            titleField.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 6),
            progressIndicator.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor),
            placeholderField.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
            placeholderField.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor),
            placeholderField.widthAnchor.constraint(lessThanOrEqualTo: thumbnailView.widthAnchor, constant: -12)
        ])
    }

    func configure(record: AssetGridRecord, state: AssetThumbnailState?, imageSize: Double) {
        titleField.stringValue = record.displayName
        view.setAccessibilityLabel(record.displayName)
        view.setAccessibilityIdentifier("asset.\(record.id.description)")
        thumbnailView.image = nil
        placeholderField.stringValue = ""
        placeholderField.isHidden = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true

        switch state {
        case let .ready(payload):
            if let image = NSImage(data: payload.encodedData) {
                thumbnailView.image = image
            } else {
                showPlaceholder(symbol: "exclamationmark.triangle", label: "Corrupt thumbnail")
            }
        case .missing:
            showPlaceholder(symbol: "questionmark.folder", label: "Original missing")
        case .corrupt:
            showPlaceholder(symbol: "exclamationmark.triangle", label: "Image unreadable")
        case .loading:
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        case nil:
            showPlaceholder(symbol: "photo", label: "")
        }
        updateSelectionAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailView.image = nil
        progressIndicator.stopAnimation(nil)
        placeholderField.stringValue = ""
    }

    private func showPlaceholder(symbol: String, label: String) {
        let symbolText = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        thumbnailView.image = symbolText
        thumbnailView.contentTintColor = .secondaryLabelColor
        if !label.isEmpty {
            placeholderField.stringValue = label
            placeholderField.isHidden = false
        }
    }

    private func updateSelectionAppearance() {
        view.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            : NSColor.clear.cgColor
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let assetCollectionItem = Self("FramebaseAssetCollectionItem")
}
