import SwiftUI
import AppKit
import AppIntents

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

        context.coordinator.outlineView = outlineView
        context.coordinator.installReloadBridge()
        outlineView.reloadData()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate, NSTableViewAppIntentsDataSource {
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
                accessibilityDescription: nil
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

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            (item as? FileNode)?.url as NSURL?
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
            }
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
    }
}

/// `NSOutlineView` subclass that supplies a per-row context menu, starts a
/// rename on Return, and vends the selected file to Services / macOS
/// intelligence.
final class TreeOutlineView: NSOutlineView, NSServicesMenuRequestor {
    private var selectedNode: FileNode? {
        selectedRow >= 0 ? item(atRow: selectedRow) as? FileNode : nil
    }

    override func keyDown(with event: NSEvent) {
        // Return begins editing the selected row's name.
        if event.keyCode == 36, selectedRow >= 0 {
            editColumn(0, row: selectedRow, with: nil, select: true)
            return
        }
        super.keyDown(with: event)
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
