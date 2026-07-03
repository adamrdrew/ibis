import Foundation
import Observation
import AppKit

/// The live state for a single window: the opened folder (or file), its file
/// tree, and (in later phases) open tabs and pane layout.
@Observable
final class Workspace {
    let rootURL: URL
    let isDirectory: Bool
    let rootNode: FileNode
    let layout = EditorLayout()
    let terminal: TerminalDock
    let git: GitStatusModel

    /// Holds security-scoped access to the root open for the workspace's lifetime.
    private let access: SecurityScopedAccess

    /// Open documents, keyed by URL, so the same file reused across tabs/panes
    /// shares one text buffer and unsaved edits survive switching away and back.
    private var documentCache: [URL: OpenDocument] = [:]

    /// Live filesystem watcher that keeps the tree in sync with disk.
    private var watcher: FileSystemWatcher?

    /// Called after a directory node's children are reloaded (from disk changes
    /// or our own operations) so the outline view can refresh that item.
    var onDirectoryReloaded: ((FileNode) -> Void)?

    init(rootURL: URL, isDirectory: Bool) {
        self.rootURL = rootURL
        self.isDirectory = isDirectory
        self.access = SecurityScopedAccess(url: rootURL)
        self.rootNode = FileNode(url: rootURL, isDirectory: isDirectory)
        // Terminals and Git status use the folder (or a single file's folder).
        let terminalRoot = isDirectory ? rootURL : rootURL.deletingLastPathComponent()
        self.terminal = TerminalDock(workingDirectory: terminalRoot)
        self.git = GitStatusModel(root: terminalRoot)

        if isDirectory {
            watcher = FileSystemWatcher(path: rootURL.path(percentEncoded: false)) { [weak self] paths in
                Task { @MainActor in
                    await self?.handleFileSystemChanges(paths)
                }
            }
        }

        git.refresh()
    }

    /// Immediately re-reads a directory node (if loaded), for snappy updates
    /// after our own file operations without waiting for the FSEvents latency.
    func reloadDirectory(at url: URL) async {
        if let node = loadedDirectoryNode(matching: url.standardizedFileURL) {
            await node.reloadChildrenMerging()
            onDirectoryReloaded?(node)
        }
    }

    /// Reloads the loaded directory nodes affected by filesystem changes.
    private func handleFileSystemChanges(_ paths: [String]) async {
        // Any change on disk (including inside .git — commits, branch switches,
        // staging) may affect Git status, so refresh it too.
        git.refresh()

        var reloaded = Set<URL>()
        for path in paths {
            let directory = URL(filePath: path).standardizedFileURL
            guard !reloaded.contains(directory),
                  let node = loadedDirectoryNode(matching: directory) else { continue }
            reloaded.insert(directory)
            await node.reloadChildrenMerging()
            onDirectoryReloaded?(node)
        }
    }

    /// Finds an already-loaded directory node whose URL matches, walking only
    /// loaded branches (unexpanded subtrees refresh themselves when opened).
    private func loadedDirectoryNode(matching directory: URL) -> FileNode? {
        let target = directory.standardizedFileURL.path
        func search(_ node: FileNode) -> FileNode? {
            if node.isDirectory, node.isLoaded, node.url.standardizedFileURL.path == target {
                return node
            }
            for child in node.children ?? [] where child.isDirectory {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(rootNode)
    }

    var displayName: String {
        rootURL.lastPathComponent
    }

    /// Returns the cached document for a URL, creating (but not yet loading) one
    /// on first request.
    func document(for url: URL) -> OpenDocument {
        if let existing = documentCache[url] {
            return existing
        }
        let document = OpenDocument(url: url)
        documentCache[url] = document
        return document
    }

    // MARK: - Menu actions (operate on the active pane / document)

    var activeDocument: OpenDocument? {
        layout.activePane?.selectedDocument
    }

    func saveActiveDocument() async {
        await activeDocument?.save()
    }

    /// Writes the active document's text to a new location chosen by the user,
    /// then opens that file in the active pane.
    func saveActiveDocumentAs() {
        guard let document = activeDocument else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url.lastPathComponent
        panel.directoryURL = document.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = document.text
        Task {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            let saved = self.document(for: url)
            await saved.loadIfNeeded()
            layout.activePane?.open(saved)
        }
    }

    func closeActiveTab() {
        guard let pane = layout.activePane, let url = pane.selectedURL else { return }
        requestCloseTab(url: url, in: pane)
    }

    /// Closes a tab, prompting to save first if the document has unsaved changes
    /// and isn't still open in another pane.
    func requestCloseTab(url: URL, in pane: EditorPane) {
        guard let document = pane.tabDocuments.first(where: { $0.url == url }) else { return }

        if document.isDirty && !isOpenElsewhere(url: url, excluding: pane) {
            switch confirmSave(
                message: "Do you want to save the changes you made to “\(document.name)”?",
                informative: "Your changes will be lost if you don’t save them."
            ) {
            case .cancel:
                return
            case .discard:
                discardDocument(url)
            case .save:
                Task {
                    if await document.save() { self.closeTab(url, in: pane) }
                }
                return
            }
        }
        closeTab(url, in: pane)
    }

    private func closeTab(_ url: URL, in pane: EditorPane) {
        pane.close(url)
        if pane.tabDocuments.isEmpty && layout.panes.count > 1 {
            layout.closePane(pane.id)
        }
    }

    private func isOpenElsewhere(url: URL, excluding pane: EditorPane) -> Bool {
        layout.panes.contains { $0.id != pane.id && $0.tabDocuments.contains { $0.url == url } }
    }

    /// Drops a document's buffer so its unsaved edits are truly discarded; a
    /// later reopen reads fresh from disk.
    private func discardDocument(_ url: URL) {
        documentCache.removeValue(forKey: url)
    }

    func splitActiveEditor() {
        layout.splitActive()
    }

    /// Moves selection to an adjacent tab in the active pane, wrapping around.
    func selectAdjacentTab(offset: Int) {
        guard let pane = layout.activePane,
              !pane.tabDocuments.isEmpty,
              let current = pane.tabDocuments.firstIndex(where: { $0.url == pane.selectedURL })
        else { return }
        let count = pane.tabDocuments.count
        let next = (current + offset + count) % count
        pane.selectedURL = pane.tabDocuments[next].url
    }

    func revealActiveInFinder() {
        guard let url = activeDocument?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Terminal actions

    func toggleTerminal() {
        terminal.toggle()
    }

    func newTerminalTab() {
        terminal.newSession()
        terminal.isVisible = true
    }

    func closeActiveTerminalTab() {
        guard let id = terminal.activeSessionID else { return }
        terminal.closeSession(id)
    }

    func selectAdjacentTerminal(offset: Int) {
        terminal.selectAdjacent(offset: offset)
    }

    /// Reveals the terminal dock and launches the configured agent in a fresh
    /// terminal tab, rooted at the workspace.
    func runAgent(command: String, name: String) {
        terminal.newSession(command: command, title: name)
        terminal.isVisible = true
    }

    // MARK: - Unsaved changes

    private enum SaveDecision { case save, discard, cancel }

    /// Distinct documents with unsaved edits that are currently open in a tab.
    var dirtyDocuments: [OpenDocument] {
        var seen = Set<URL>()
        var result: [OpenDocument] = []
        for pane in layout.panes {
            for document in pane.tabDocuments where document.isDirty && !seen.contains(document.url) {
                seen.insert(document.url)
                result.append(document)
            }
        }
        return result
    }

    /// Called from the window's close guard: prompts if there are unsaved
    /// changes and returns whether the window may close.
    func confirmWindowClose() -> Bool {
        let dirty = dirtyDocuments
        guard !dirty.isEmpty else { return true }

        let message = dirty.count == 1
            ? "Do you want to save the changes you made to “\(dirty[0].name)”?"
            : "You have \(dirty.count) documents with unsaved changes."
        switch confirmSave(message: message, informative: "Your changes will be lost if you don’t save them.") {
        case .cancel:
            return false
        case .discard:
            return true
        case .save:
            for document in dirty { document.saveSynchronously() }
            return true
        }
    }

    /// Shows the standard Save / Cancel / Don't Save sheet-style alert.
    private func confirmSave(message: String, informative: String) -> SaveDecision {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}
