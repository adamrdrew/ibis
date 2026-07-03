import SwiftUI
import AppKit
import AppIntents
import Quartz

/// The sidebar file browser, backed by `NSOutlineView` for native, Finder-grade
/// behavior: click-to-open, inline rename (double-click / Enter), a right-click
/// menu, and drag-and-drop (internal move, ⌥-copy, and in/out of Finder). The
/// tree data comes from the workspace's `FileNode`s and stays live via FSEvents.
struct FileOutlineView: NSViewRepresentable {
    let workspace: Workspace
    @Binding var selection: FileNode.ID?

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace, selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = TreeOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .default
        outlineView.autoresizesOutlineColumn = false
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        // Use the standard `.menu` path (populated in `menuNeedsUpdate`) so
        // AppKit augments it with the system Services and macOS intelligence
        // ("Ask Siri" / Writing Tools) items, based on `validRequestor`.
        let contextMenu = NSMenu()
        contextMenu.delegate = context.coordinator
        contextMenu.allowsContextMenuPlugIns = true
        outlineView.menu = contextMenu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // Annotate rows with their file entity so the system offers "Ask Siri".
        outlineView.appIntentsDataSource = context.coordinator

        outlineView.coordinator = context.coordinator
        context.coordinator.outlineView = outlineView
        context.coordinator.installReloadBridge()
        outlineView.reloadData()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate, NSTableViewAppIntentsDataSource, NSMenuItemValidation {
        private let workspace: Workspace
        private let selection: Binding<FileNode.ID?>
        weak var outlineView: TreeOutlineView?

        /// The row the context menu was opened on, for the menu's @objc actions.
        private var contextNode: FileNode?

        init(workspace: Workspace, selection: Binding<FileNode.ID?>) {
            self.workspace = workspace
            self.selection = selection
        }

        /// Wire filesystem/operation reloads to `NSOutlineView.reloadItem`.
        func installReloadBridge() {
            workspace.onDirectoryReloaded = { [weak self] node in
                guard let self, let outlineView = self.outlineView else { return }
                if node === self.workspace.rootNode {
                    outlineView.reloadItem(nil, reloadChildren: true)
                } else {
                    outlineView.reloadItem(node, reloadChildren: true)
                }
            }
            workspace.onRevealInTree = { [weak self] url in
                self?.revealInTree(url)
            }
        }

        /// Expands the folder chain down to `url` and selects its row (MCP
        /// `reveal_in_tree`). Selecting a file also opens it, matching a click.
        func revealInTree(_ url: URL) {
            guard let outlineView else { return }
            let root = workspace.rootNode
            let rootPath = root.url.resolvingSymlinksInPath().standardizedFileURL.path
            let targetPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return }

            var node = root
            let rest = targetPath.dropFirst(rootPath.count)
                .split(separator: "/").map(String.init)
            for (index, component) in rest.enumerated() {
                node.loadChildrenSyncIfNeeded()
                guard let child = node.children?.first(where: { $0.url.lastPathComponent == component }) else {
                    break
                }
                node = child
                // Expand every intermediate directory so the target row exists.
                if index < rest.count - 1, child.isDirectory {
                    outlineView.expandItem(child)
                }
            }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }

        // MARK: Data source

        private func children(of item: Any?) -> [FileNode] {
            if let node = item as? FileNode {
                node.loadChildrenSyncIfNeeded()
                return node.children ?? []
            }
            let root = workspace.rootNode
            if root.isDirectory {
                root.loadChildrenSyncIfNeeded()
                return root.children ?? []
            }
            return [root]
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileNode)?.isDirectory ?? false
        }

        // MARK: App Intents entity annotation (drives the "Ask Siri" item)

        func outlineView(_ outlineView: NSOutlineView, appEntityIdentifierFor item: Any?) -> EntityIdentifier? {
            guard let node = item as? FileNode, !node.isDirectory,
                  let fileID = try? FileEntityIdentifier.file(url: node.url) else { return nil }
            return EntityIdentifier(for: WorkspaceFileEntity.self, identifier: fileID)
        }

        // MARK: Delegate — cells & selection

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("FileCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? makeCell(identifier: identifier)
            cell.textField?.stringValue = node.name
            cell.imageView?.image = NSImage(
                systemSymbolName: FileIconProvider.symbolName(for: node),
                accessibilityDescription: node.isDirectory ? "Folder" : "File"
            )
            cell.imageView?.contentTintColor = node.isDirectory
                ? NSColor(Color.ibisKelly)
                : .secondaryLabelColor
            return cell
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.isEditable = true
            textField.isBordered = false
            textField.drawsBackground = false
            textField.lineBreakMode = .byTruncatingTail
            textField.delegate = self
            textField.target = self
            textField.action = #selector(commitRename(_:))

            cell.imageView = imageView
            cell.textField = textField
            cell.addSubview(imageView)
            cell.addSubview(textField)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView = notification.object as? NSOutlineView else { return }
            // Keep an open Quick Look panel in sync as selection moves.
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
            let row = outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode, !node.isDirectory else {
                return
            }
            selection.wrappedValue = node.id
        }

        // MARK: Inline rename

        @objc private func commitRename(_ sender: NSTextField) {
            performRename(from: sender)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            performRename(from: field)
        }

        private func performRename(from field: NSTextField) {
            guard let outlineView, let node = node(forCellSubview: field) else { return }
            let newName = field.stringValue
            guard newName != node.name else { return }
            let parent = node.url.deletingLastPathComponent()
            guard (try? FileOperations.rename(node.url, to: newName)) != nil else {
                field.stringValue = node.name // revert on failure
                return
            }
            Task { await workspace.reloadDirectory(at: parent) }
            _ = outlineView
        }

        private func node(forCellSubview view: NSView) -> FileNode? {
            guard let outlineView else { return nil }
            let row = outlineView.row(for: view)
            return row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil
        }

        func beginRename(_ node: FileNode) {
            guard let outlineView else { return }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.editColumn(0, row: row, with: nil, select: true)
        }

        // MARK: Drag & drop

        /// The folder a spring-load expand is pending for, and its timer.
        private var springItem: FileNode?
        private var springWorkItem: DispatchWorkItem?

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            (item as? FileNode)?.url as NSURL?
        }

        /// Schedules (or cancels) an auto-expand for a collapsed folder hovered
        /// during a drag, Finder-style.
        private func scheduleSpring(for node: FileNode?, in outlineView: NSOutlineView) {
            guard let node, node.isDirectory, !outlineView.isItemExpanded(node) else {
                cancelSpring()
                return
            }
            if node === springItem { return } // already pending for this folder
            springWorkItem?.cancel()
            springItem = node
            let work = DispatchWorkItem { [weak outlineView] in
                outlineView?.animator().expandItem(node)
            }
            springWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
        }

        func cancelSpring() {
            springWorkItem?.cancel()
            springWorkItem = nil
            springItem = nil
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            // Only drop onto directories (or the root when item is nil).
            if let node = item as? FileNode, !node.isDirectory { return [] }
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)

            // Spring-load: hovering a collapsed folder during a drag expands it.
            scheduleSpring(for: item as? FileNode, in: outlineView)

            let optionHeld = info.draggingSourceOperationMask == .copy
            let isInternal = (info.draggingSource as? NSOutlineView) === outlineView
            if isInternal {
                return optionHeld ? .copy : .move
            }
            return .copy
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            let targetDirectory = (item as? FileNode)?.url ?? workspace.rootURL
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
                  !urls.isEmpty else { return false }

            cancelSpring()

            let isInternal = (info.draggingSource as? NSOutlineView) === outlineView
            let optionHeld = info.draggingSourceOperationMask == .copy
            let move = isInternal && !optionHeld

            var affected: Set<URL> = [targetDirectory]
            for source in urls {
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }

                let destination = FileOperations.uniqueURL(in: targetDirectory, baseName: source.lastPathComponent)
                if move {
                    try? FileManager.default.moveItem(at: source, to: destination)
                    affected.insert(source.deletingLastPathComponent())
                } else {
                    try? FileManager.default.copyItem(at: source, to: destination)
                }
            }

            Task {
                for directory in affected {
                    await workspace.reloadDirectory(at: directory)
                }
            }
            return true
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outlineView else { menu.removeAllItems(); return }
            // Target the right-clicked row and select it, so the Services /
            // intelligence machinery vends that file via `validRequestor`.
            let row = outlineView.clickedRow
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let node = row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil
            contextNode = node

            menu.removeAllItems()
            menu.addItem(menuItem("New File", #selector(newFile)))
            menu.addItem(menuItem("New Folder", #selector(newFolder)))

            if let node {
                menu.addItem(.separator())
                menu.addItem(menuItem("Rename", #selector(rename)))
                menu.addItem(menuItem("Move to Trash", #selector(moveToTrash)))
                menu.addItem(.separator())
                menu.addItem(menuItem("Reveal in Finder", #selector(reveal)))
                if node.isDirectory {
                    menu.addItem(menuItem("Open in Terminal", #selector(openInTerminal)))
                }
                menu.addItem(menuItem("Copy Path", #selector(copyPath)))
                menu.addItem(menuItem("Copy Name", #selector(copyName)))
                menu.addItem(menuItem("Share…", #selector(share)))
                menu.addItem(.separator())
                menu.addItem(menuItem("Copy", #selector(copyItems)))
                menu.addItem(menuItem("Cut", #selector(cutItems)))
            }
            menu.addItem(.separator())
            menu.addItem(menuItem("Paste", #selector(pasteItems)))
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        private var creationDirectory: URL {
            guard let node = contextNode else { return workspace.rootURL }
            return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        }

        @objc private func newFile() { create(directory: false) }
        @objc private func newFolder() { create(directory: true) }

        private func create(directory: Bool) {
            let target = creationDirectory
            if let node = contextNode, node.isDirectory, let outlineView {
                outlineView.expandItem(node)
            }
            let newURL = directory
                ? try? FileOperations.createFolder(in: target)
                : try? FileOperations.createFile(in: target)
            guard let newURL else { return }
            Task {
                await workspace.reloadDirectory(at: target)
                if let node = loadedNode(for: newURL) {
                    beginRename(node)
                }
            }
        }

        private func loadedNode(for url: URL) -> FileNode? {
            let target = url.standardizedFileURL.path
            func search(_ node: FileNode) -> FileNode? {
                if node.url.standardizedFileURL.path == target { return node }
                for child in node.children ?? [] {
                    if let found = search(child) { return found }
                }
                return nil
            }
            return search(workspace.rootNode)
        }

        @objc private func rename() {
            if let node = contextNode { beginRename(node) }
        }

        @objc private func moveToTrash() {
            guard let node = contextNode else { return }
            let parent = node.url.deletingLastPathComponent()
            try? FileOperations.moveToTrash(node.url)
            Task { await workspace.reloadDirectory(at: parent) }
        }

        @objc private func reveal() {
            if let node = contextNode { FileOperations.revealInFinder(node.url) }
        }

        @objc private func openInTerminal() {
            if let node = contextNode { FileOperations.openInTerminal(node.url) }
        }

        @objc private func copyPath() {
            if let node = contextNode {
                FileOperations.copyToPasteboard(node.url.path(percentEncoded: false))
            }
        }

        @objc private func copyName() {
            if let node = contextNode { FileOperations.copyToPasteboard(node.name) }
        }

        @objc private func share() {
            guard let node = contextNode, let outlineView else { return }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            SharePresenter.shared.share([node.url], relativeTo: outlineView.rect(ofRow: row), of: outlineView)
        }

        // MARK: - Copy / Cut / Paste of files

        /// True after a Cut, so the next Paste moves rather than copies.
        private var pasteboardMove = false

        private var selectedFileNode: FileNode? {
            guard let outlineView, outlineView.selectedRow >= 0 else { return nil }
            return outlineView.item(atRow: outlineView.selectedRow) as? FileNode
        }

        private var pasteDestination: URL {
            guard let node = selectedFileNode else { return workspace.rootURL }
            return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        }

        var hasSelection: Bool { selectedFileNode != nil }

        func canPaste() -> Bool {
            NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
        }

        func performCopy(cut: Bool) {
            guard let node = selectedFileNode else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([node.url as NSURL])
            pasteboardMove = cut
        }

        func performPaste() {
            let destination = pasteDestination
            guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL],
                  !urls.isEmpty else { return }
            let move = pasteboardMove
            pasteboardMove = false

            var affected: Set<URL> = [destination]
            for source in urls {
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }

                let target = FileOperations.uniqueURL(in: destination, baseName: source.lastPathComponent)
                if move {
                    try? FileManager.default.moveItem(at: source, to: target)
                    affected.insert(source.deletingLastPathComponent())
                } else {
                    try? FileManager.default.copyItem(at: source, to: target)
                }
            }

            Task {
                for directory in affected {
                    await workspace.reloadDirectory(at: directory)
                }
            }
        }

        @objc private func copyItems() { performCopy(cut: false) }
        @objc private func cutItems() { performCopy(cut: true) }
        @objc private func pasteItems() { performPaste() }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(pasteItems) { return canPaste() }
            return true
        }

        // MARK: - Quick Look

        /// The URLs of the current selection, previewed by Quick Look (Space).
        var selectedFileURLs: [URL] {
            guard let outlineView else { return [] }
            return outlineView.selectedRowIndexes.compactMap {
                (outlineView.item(atRow: $0) as? FileNode)?.url
            }
        }
    }
}

// MARK: - Quick Look panel data source / delegate

extension FileOutlineView.Coordinator: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedFileURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        selectedFileURLs[index] as NSURL
    }

    /// Forward arrow keys to the outline so selection (and the preview) can move
    /// while the panel has key focus.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 {
            outlineView?.keyDown(with: event)
            return true
        }
        return false
    }
}

/// `NSOutlineView` subclass that supplies a per-row context menu, starts a
/// rename on Return, and vends the selected file to Services / macOS
/// intelligence.
final class TreeOutlineView: NSOutlineView, NSServicesMenuRequestor, NSMenuItemValidation {
    weak var coordinator: FileOutlineView.Coordinator?

    private var selectedNode: FileNode? {
        selectedRow >= 0 ? item(atRow: selectedRow) as? FileNode : nil
    }

    // ⌘C / ⌘X / ⌘V route here (from the standard Edit menu) when the tree is
    // the first responder, so files copy/cut/paste contextually.
    @objc func copy(_ sender: Any?) { coordinator?.performCopy(cut: false) }
    @objc func cut(_ sender: Any?) { coordinator?.performCopy(cut: true) }
    @objc func paste(_ sender: Any?) { coordinator?.performPaste() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return coordinator?.hasSelection ?? false
        case #selector(paste(_:)):
            return coordinator?.canPaste() ?? false
        default:
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return begins editing the selected row's name.
        if event.keyCode == 36, selectedRow >= 0 {
            editColumn(0, row: selectedRow, with: nil, select: true)
            return
        }
        // Space toggles Quick Look for the selected file(s).
        if event.keyCode == 49, let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        coordinator?.cancelSpring()
        super.draggingExited(sender)
    }

    // MARK: - Quick Look panel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = coordinator
        panel.delegate = coordinator
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - Services requestor

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if returnType == nil,
           let sendType,
           sendType == .fileURL || sendType == .string,
           selectedNode != nil {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let node = selectedNode else { return false }
        pboard.clearContents()
        var wrote = false
        if types.contains(.fileURL) {
            pboard.writeObjects([node.url as NSURL])
            wrote = true
        }
        if types.contains(.string) {
            pboard.setString(node.url.path(percentEncoded: false), forType: .string)
            wrote = true
        }
        return wrote
    }
}
