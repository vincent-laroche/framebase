import AppKit
import FramebaseDomain
import SwiftUI

struct SidebarFolderDrop: Equatable, Sendable {
    let sourceFolderID: FolderID
    let destinationParentFolderID: FolderID?
}

enum SidebarContextAction: Equatable, Sendable {
    case createFolder(parentFolderID: FolderID?)
    case deleteFolder(FolderID)
}

enum SidebarDropDisposition: Equatable, Sendable {
    case allowed
    case rejected
}

/// A narrow AppKit adapter for source-list behavior that SwiftUI does not expose.
/// All durable state and mutations remain owned by the SwiftUI window model.
struct FoundationSidebar: NSViewRepresentable {
    var folderTree: FolderTreeSnapshot?
    var albums: [Album]
    @Binding var selection: NavigationTarget?
    @Binding var expandedFolderIDs: Set<FolderID>
    @Binding var isKeyboardFocused: Bool
    var focusRequestGeneration: Int
    var onRenameFolder: (FolderID, String) -> Void
    var onContextAction: (SidebarContextAction) -> Void
    var validateFolderDrop: (SidebarFolderDrop) -> SidebarDropDisposition
    var onReparentFolder: (SidebarFolderDrop) -> Void

    init(
        folderTree: FolderTreeSnapshot? = nil,
        albums: [Album] = [],
        selection: Binding<NavigationTarget?>,
        expandedFolderIDs: Binding<Set<FolderID>> = .constant([]),
        isKeyboardFocused: Binding<Bool> = .constant(false),
        focusRequestGeneration: Int = 0,
        onRenameFolder: @escaping (FolderID, String) -> Void = { _, _ in },
        onContextAction: @escaping (SidebarContextAction) -> Void = { _ in },
        validateFolderDrop: @escaping (SidebarFolderDrop) -> SidebarDropDisposition = { _ in .rejected },
        onReparentFolder: @escaping (SidebarFolderDrop) -> Void = { _ in }
    ) {
        self.folderTree = folderTree
        self.albums = albums
        _selection = selection
        _expandedFolderIDs = expandedFolderIDs
        _isKeyboardFocused = isKeyboardFocused
        self.focusRequestGeneration = focusRequestGeneration
        self.onRenameFolder = onRenameFolder
        self.onContextAction = onContextAction
        self.validateFolderDrop = validateFolderDrop
        self.onReparentFolder = onReparentFolder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = SidebarOutlineView()
        let column = NSTableColumn(identifier: .sidebarColumn)
        column.resizingMask = .autoresizingMask

        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsColumnResizing = false
        outlineView.autosaveExpandedItems = false
        outlineView.indentationPerLevel = 14
        outlineView.floatsGroupRows = false
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        outlineView.registerForDraggedTypes([.framebaseFolder])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.focusRingType = .exterior
        outlineView.menu = context.coordinator.contextMenu
        outlineView.onFocusChanged = { [weak coordinator = context.coordinator] isFocused in
            coordinator?.reportFocus(isFocused)
        }
        outlineView.onRenameSelected = { [weak coordinator = context.coordinator] in
            coordinator?.beginRenamingSelectedFolder()
        }
        outlineView.onDeleteSelected = { [weak coordinator = context.coordinator] in
            coordinator?.deleteSelectedFolder()
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView

        context.coordinator.attach(outlineView)
        context.coordinator.applyContent(folderTree: folderTree, albums: albums)
        context.coordinator.synchronizeFromSwiftUI()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let outlineView = scrollView.documentView as? SidebarOutlineView else { return }

        context.coordinator.parent = self
        context.coordinator.attach(outlineView)
        context.coordinator.applyContent(folderTree: folderTree, albums: albums)
        context.coordinator.synchronizeFromSwiftUI()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: FoundationSidebar

        let contextMenu = NSMenu(title: "Sidebar")

        private weak var outlineView: SidebarOutlineView?
        private var rootNodes: [SidebarNode] = []
        private var nodesByID: [SidebarNodeID: SidebarNode] = [:]
        private var folderParentByID: [FolderID: FolderID?] = [:]
        private var contentSignature: SidebarContentSignature?
        private var isSynchronizing = false
        private var lastFocusRequestGeneration: Int
        private var contextMenuNode: SidebarNode?
        private var hoveredFolderID: FolderID?
        private var hoverExpansionTask: Task<Void, Never>?

        init(parent: FoundationSidebar) {
            self.parent = parent
            lastFocusRequestGeneration = parent.focusRequestGeneration
            super.init()
            contextMenu.delegate = self
        }

        deinit {
            hoverExpansionTask?.cancel()
        }

        fileprivate func attach(_ outlineView: SidebarOutlineView) {
            self.outlineView = outlineView
        }

        func applyContent(folderTree: FolderTreeSnapshot?, albums: [Album]) {
            let signature = SidebarContentSignature(folderTree: folderTree, albums: albums)
            guard signature != contentSignature else { return }

            contentSignature = signature
            rebuildNodes(folderTree: folderTree, albums: albums)
            outlineView?.reloadData()
        }

        func synchronizeFromSwiftUI() {
            guard let outlineView else { return }

            isSynchronizing = true
            defer { isSynchronizing = false }

            expandPermanentGroups(in: outlineView)

            let validExpandedIDs = parent.expandedFolderIDs.intersection(folderParentByID.keys)
            if validExpandedIDs != parent.expandedFolderIDs {
                parent.expandedFolderIDs = validExpandedIDs
            }
            for (folderID, _) in folderParentByID {
                guard let node = nodesByID[.folder(folderID)] else { continue }
                if validExpandedIDs.contains(folderID) {
                    if !outlineView.isItemExpanded(node) {
                        outlineView.expandItem(node)
                    }
                } else if outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node)
                }
            }

            synchronizeSelection(in: outlineView)

            if parent.focusRequestGeneration != lastFocusRequestGeneration {
                lastFocusRequestGeneration = parent.focusRequestGeneration
                outlineView.window?.makeFirstResponder(outlineView)
            }
        }

        func reportFocus(_ isFocused: Bool) {
            guard parent.isKeyboardFocused != isFocused else { return }
            parent.isKeyboardFocused = isFocused
        }

        func beginRenamingSelectedFolder() {
            guard let outlineView,
                  let node = selectedNode(in: outlineView),
                  case .folder = node.id else { return }

            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.editColumn(0, row: row, with: nil, select: true)
        }

        func deleteSelectedFolder() {
            guard let outlineView,
                  let node = selectedNode(in: outlineView),
                  case let .folder(folderID) = node.id else { return }
            parent.onContextAction(.deleteFolder(folderID))
        }

        func numberOfChildren(of item: Any?) -> Int {
            guard let item else { return rootNodes.count }
            return (item as? SidebarNode)?.children.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            numberOfChildren(of: item)
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? SidebarNode {
                return node.children[index]
            }
            return rootNodes[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return node.isGroup || !node.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? SidebarNode)?.isGroup == true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            (item as? SidebarNode)?.isGroup != true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? SidebarNode)?.navigationTarget != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            if case .folder = node.id {
                return true
            }
            return false
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            return node.isGroup
                ? makeGroupCell(for: node, in: outlineView)
                : makeItemCell(for: node, in: outlineView)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizing,
                  let outlineView,
                  outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode,
                  let target = node.navigationTarget,
                  parent.selection != target else { return }
            parent.selection = target
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSynchronizing,
                  let node = notification.userInfo?["NSObject"] as? SidebarNode,
                  case let .folder(folderID) = node.id else { return }
            parent.expandedFolderIDs.insert(folderID)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSynchronizing,
                  let node = notification.userInfo?["NSObject"] as? SidebarNode,
                  case let .folder(folderID) = node.id else { return }
            parent.expandedFolderIDs.remove(folderID)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField,
                  let cell = textField.superview as? SidebarCellView,
                  let node = cell.node,
                  case let .folder(folderID) = node.id else { return }

            let proposedName = textField.stringValue
            textField.stringValue = node.title
            if proposedName != node.title {
                parent.onRenameFolder(folderID, proposedName)
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            pasteboardWriterForItem item: Any
        ) -> (any NSPasteboardWriting)? {
            guard let node = item as? SidebarNode,
                  case let .folder(folderID) = node.id else { return nil }

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(folderID.description, forType: .framebaseFolder)
            return pasteboardItem
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: any NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let drop = folderDrop(from: info, destinationItem: item),
                  isStructurallyValid(drop),
                  parent.validateFolderDrop(drop) == .allowed else {
                cancelHoverExpansion()
                return []
            }

            if let destinationID = drop.destinationParentFolderID,
               let destinationNode = nodesByID[.folder(destinationID)] {
                outlineView.setDropItem(destinationNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
                scheduleHoverExpansion(for: destinationID, node: destinationNode)
            } else if let foldersGroup = nodesByID[.group(.folders)] {
                outlineView.setDropItem(foldersGroup, dropChildIndex: NSOutlineViewDropOnItemIndex)
                cancelHoverExpansion()
            }

            return .move
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: any NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            defer { cancelHoverExpansion() }
            guard let drop = folderDrop(from: info, destinationItem: item),
                  isStructurallyValid(drop),
                  parent.validateFolderDrop(drop) == .allowed else { return false }
            parent.onReparentFolder(drop)
            return true
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outlineView else { return }
            menu.removeAllItems()
            contextMenuNode = selectedOrClickedNode(in: outlineView)
            if outlineView.clickedRow >= 0,
               contextMenuNode?.navigationTarget != nil,
               outlineView.selectedRow != outlineView.clickedRow {
                outlineView.selectRowIndexes(
                    IndexSet(integer: outlineView.clickedRow),
                    byExtendingSelection: false
                )
            }

            switch contextMenuNode?.id {
            case .group(.folders), .placeholder(.folders):
                menu.addItem(menuItem("New Folder", action: #selector(createRootFolder)))
            case .folder:
                menu.addItem(menuItem("New Subfolder", action: #selector(createSubfolder)))
                menu.addItem(.separator())
                menu.addItem(menuItem("Rename", action: #selector(renameFolder)))
                menu.addItem(menuItem("Delete Folder", action: #selector(deleteFolder)))
            default:
                break
            }
        }

        @objc private func createRootFolder() {
            parent.onContextAction(.createFolder(parentFolderID: nil))
        }

        @objc private func createSubfolder() {
            guard case let .folder(folderID) = contextMenuNode?.id else { return }
            parent.onContextAction(.createFolder(parentFolderID: folderID))
        }

        @objc private func renameFolder() {
            beginRenamingSelectedFolder()
        }

        @objc private func deleteFolder() {
            guard case let .folder(folderID) = contextMenuNode?.id else { return }
            parent.onContextAction(.deleteFolder(folderID))
        }

        private func rebuildNodes(folderTree: FolderTreeSnapshot?, albums: [Album]) {
            nodesByID.removeAll(keepingCapacity: true)
            folderParentByID.removeAll(keepingCapacity: true)

            let libraryGroup = SidebarNode(id: .group(.library), title: "Library", isGroup: true)
            libraryGroup.children = [
                destinationNode(.allAssets, title: "All Assets", symbolName: "photo.on.rectangle.angled"),
                destinationNode(.inbox, title: "Inbox", symbolName: "tray"),
                destinationNode(.favorites, title: "Favorites", symbolName: "heart")
            ]

            let foldersGroup = SidebarNode(id: .group(.folders), title: "Folders", isGroup: true)
            if let folderTree {
                let foldersByID = Dictionary(uniqueKeysWithValues: folderTree.folders.map { ($0.id, $0) })
                for folder in folderTree.folders where folder.systemKind == nil {
                    folderParentByID[folder.id] = folder.parentFolderID
                }
                foldersGroup.children = folderTree.roots.compactMap {
                    makeFolderNode(id: $0, foldersByID: foldersByID, childrenByParent: folderTree.childrenByParent)
                }
            }
            if foldersGroup.children.isEmpty {
                foldersGroup.children = [SidebarNode(id: .placeholder(.folders), title: "No folders yet")]
            }

            let albumsGroup = SidebarNode(id: .group(.albums), title: "Albums", isGroup: true)
            albumsGroup.children = albums
                .sorted {
                    if $0.sortOrder != $1.sortOrder {
                        return $0.sortOrder < $1.sortOrder
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                .map { album in
                    SidebarNode(
                        id: .album(album.id),
                        title: album.name,
                        symbolName: "rectangle.stack",
                        navigationTarget: .album(album.id)
                    )
                }
            if albumsGroup.children.isEmpty {
                albumsGroup.children = [SidebarNode(id: .placeholder(.albums), title: "No albums yet")]
            }

            rootNodes = [libraryGroup, foldersGroup, albumsGroup]
            indexNodes(rootNodes)
        }

        private func destinationNode(
            _ target: NavigationTarget,
            title: String,
            symbolName: String
        ) -> SidebarNode {
            let node = SidebarNode(
                id: .destination(target),
                title: title,
                symbolName: symbolName,
                navigationTarget: target
            )
            nodesByID[node.id] = node
            return node
        }

        private func makeFolderNode(
            id folderID: FolderID,
            foldersByID: [FolderID: Folder],
            childrenByParent: [FolderID: [FolderID]],
            ancestors: Set<FolderID> = []
        ) -> SidebarNode? {
            guard !ancestors.contains(folderID),
                  let folder = foldersByID[folderID],
                  folder.systemKind == nil else { return nil }

            let node = SidebarNode(
                id: .folder(folderID),
                title: folder.name.rawValue,
                symbolName: "folder",
                navigationTarget: .folder(folderID)
            )
            let nextAncestors = ancestors.union([folderID])
            node.children = (childrenByParent[folderID] ?? []).compactMap {
                makeFolderNode(
                    id: $0,
                    foldersByID: foldersByID,
                    childrenByParent: childrenByParent,
                    ancestors: nextAncestors
                )
            }
            return node
        }

        private func indexNodes(_ nodes: [SidebarNode]) {
            for node in nodes {
                nodesByID[node.id] = node
                indexNodes(node.children)
            }
        }

        private func makeGroupCell(for node: SidebarNode, in outlineView: NSOutlineView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier.sidebarGroupCell
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView
                ?? SidebarCellView(identifier: identifier)
            cell.configure(with: node, group: true)
            return cell
        }

        private func makeItemCell(for node: SidebarNode, in outlineView: NSOutlineView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier.sidebarItemCell
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView
                ?? SidebarCellView(identifier: identifier)
            cell.configure(with: node, group: false)
            cell.textField?.delegate = self
            return cell
        }

        private func expandPermanentGroups(in outlineView: NSOutlineView) {
            for section in SidebarGroup.allCases {
                if let node = nodesByID[.group(section)], !outlineView.isItemExpanded(node) {
                    outlineView.expandItem(node)
                }
            }
        }

        private func synchronizeSelection(in outlineView: NSOutlineView) {
            guard let selection = parent.selection,
                  let node = nodesByID[.destination(selection)] ?? navigationNode(for: selection),
                  outlineView.row(forItem: node) >= 0 else { return }

            let row = outlineView.row(forItem: node)
            if outlineView.selectedRow != row {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        }

        private func navigationNode(for target: NavigationTarget) -> SidebarNode? {
            switch target {
            case let .folder(folderID): nodesByID[.folder(folderID)]
            case let .album(albumID): nodesByID[.album(albumID)]
            case .allAssets, .inbox, .favorites: nodesByID[.destination(target)]
            }
        }

        private func selectedOrClickedNode(in outlineView: NSOutlineView) -> SidebarNode? {
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0 else { return nil }
            return outlineView.item(atRow: row) as? SidebarNode
        }

        private func selectedNode(in outlineView: NSOutlineView) -> SidebarNode? {
            guard outlineView.selectedRow >= 0 else { return nil }
            return outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode
        }

        private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        private func folderDrop(
            from draggingInfo: any NSDraggingInfo,
            destinationItem: Any?
        ) -> SidebarFolderDrop? {
            guard let outlineView,
                  draggingInfo.draggingSource as AnyObject? === outlineView,
                  let value = draggingInfo.draggingPasteboard.string(forType: .framebaseFolder),
                  let uuid = UUID(uuidString: value) else { return nil }

            let destinationParentFolderID: FolderID?
            if let node = destinationItem as? SidebarNode {
                switch node.id {
                case let .folder(folderID):
                    destinationParentFolderID = folderID
                case .group(.folders):
                    destinationParentFolderID = nil
                default:
                    return nil
                }
            } else {
                return nil
            }

            return SidebarFolderDrop(
                sourceFolderID: FolderID(rawValue: uuid),
                destinationParentFolderID: destinationParentFolderID
            )
        }

        private func isStructurallyValid(_ drop: SidebarFolderDrop) -> Bool {
            guard folderParentByID.keys.contains(drop.sourceFolderID),
                  let sourceParent = folderParentByID[drop.sourceFolderID],
                  sourceParent != drop.destinationParentFolderID,
                  drop.sourceFolderID != drop.destinationParentFolderID else { return false }

            var ancestor = drop.destinationParentFolderID
            var visited: Set<FolderID> = []
            while let current = ancestor, visited.insert(current).inserted {
                guard current != drop.sourceFolderID else { return false }
                ancestor = folderParentByID[current] ?? nil
            }
            return true
        }

        private func scheduleHoverExpansion(for folderID: FolderID, node: SidebarNode) {
            guard hoveredFolderID != folderID else { return }
            cancelHoverExpansion()
            hoveredFolderID = folderID
            hoverExpansionTask = Task { @MainActor [weak self, weak node] in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled,
                      let self,
                      self.hoveredFolderID == folderID,
                      let node,
                      let outlineView = self.outlineView,
                      !outlineView.isItemExpanded(node) else { return }
                outlineView.expandItem(node)
            }
        }

        private func cancelHoverExpansion() {
            hoveredFolderID = nil
            hoverExpansionTask?.cancel()
            hoverExpansionTask = nil
        }
    }
}

@MainActor
private final class SidebarOutlineView: NSOutlineView {
    var onFocusChanged: ((Bool) -> Void)?
    var onRenameSelected: (() -> Void)?
    var onDeleteSelected: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChanged?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            onFocusChanged?(false)
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onRenameSelected?()
        case 51, 117:
            onDeleteSelected?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class SidebarCellView: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleField = SidebarTitleField()

    var node: SidebarNode?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.setContentHuggingPriority(.required, for: .horizontal)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true
        titleField.cell?.isScrollable = true
        titleField.onMouseDown = { [weak self] in
            self?.selectEnclosingRow()
        }

        imageView = symbolView
        textField = titleField
        addSubview(symbolView)
        addSubview(titleField)

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(with node: SidebarNode, group: Bool) {
        self.node = node
        titleField.stringValue = node.title
        titleField.isEditable = !group && node.isEditable
        titleField.isSelectable = !group && node.isEditable
        titleField.font = group ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) : .systemFont(ofSize: NSFont.systemFontSize)
        titleField.textColor = node.isPlaceholder ? .secondaryLabelColor : .labelColor
        titleField.setAccessibilityLabel(node.title)
        titleField.setAccessibilityIdentifier("sidebar.item.\(node.title)")

        symbolView.image = node.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: node.title) }
        symbolView.contentTintColor = node.isPlaceholder ? .tertiaryLabelColor : .secondaryLabelColor
        symbolView.isHidden = group || node.symbolName == nil
    }

    private func selectEnclosingRow() {
        guard let outlineView = enclosingScrollView?.documentView as? NSOutlineView else { return }
        let row = outlineView.row(for: self)
        guard row >= 0, outlineView.selectedRow != row else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

@MainActor
private final class SidebarTitleField: NSTextField {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

private enum SidebarGroup: CaseIterable, Hashable {
    case library
    case folders
    case albums
}

private enum SidebarPlaceholder: Hashable {
    case folders
    case albums
}

private enum SidebarNodeID: Hashable {
    case group(SidebarGroup)
    case destination(NavigationTarget)
    case folder(FolderID)
    case album(AlbumID)
    case placeholder(SidebarPlaceholder)
}

private final class SidebarNode: NSObject {
    let id: SidebarNodeID
    let title: String
    let symbolName: String?
    let navigationTarget: NavigationTarget?
    let isGroup: Bool
    var children: [SidebarNode] = []

    init(
        id: SidebarNodeID,
        title: String,
        symbolName: String? = nil,
        navigationTarget: NavigationTarget? = nil,
        isGroup: Bool = false
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.navigationTarget = navigationTarget
        self.isGroup = isGroup
    }

    var isPlaceholder: Bool {
        if case .placeholder = id { true } else { false }
    }

    var isEditable: Bool {
        if case .folder = id { true } else { false }
    }
}

private struct SidebarContentSignature: Equatable {
    private struct FolderValue: Equatable {
        let id: FolderID
        let name: String
        let parentID: FolderID?
        let sortOrder: Int64
        let systemKind: FolderSystemKind?
    }

    private struct AlbumValue: Equatable {
        let id: AlbumID
        let name: String
        let sortOrder: Int64
    }

    private let folders: [FolderValue]
    private let roots: [FolderID]
    private let children: [FolderID: [FolderID]]
    private let albums: [AlbumValue]

    init(folderTree: FolderTreeSnapshot?, albums: [Album]) {
        folders = folderTree?.folders.map {
            FolderValue(
                id: $0.id,
                name: $0.name.rawValue,
                parentID: $0.parentFolderID,
                sortOrder: $0.sortOrder,
                systemKind: $0.systemKind
            )
        } ?? []
        roots = folderTree?.roots ?? []
        children = folderTree?.childrenByParent ?? [:]
        self.albums = albums.map { AlbumValue(id: $0.id, name: $0.name, sortOrder: $0.sortOrder) }
    }
}

private extension NSPasteboard.PasteboardType {
    static let framebaseFolder = Self("com.vincentlaroche.framebase.folder")
}

private extension NSUserInterfaceItemIdentifier {
    static let sidebarColumn = Self("FramebaseSidebarColumn")
    static let sidebarGroupCell = Self("FramebaseSidebarGroupCell")
    static let sidebarItemCell = Self("FramebaseSidebarItemCell")
}
