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

    /// The hosting window, so unsaved-changes confirmations can attach as sheets.
    weak var window: NSWindow?

    /// True while a window-close save sheet is up, to avoid presenting a second.
    private var isPresentingCloseSheet = false

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

        // Record in the system's Recent Documents (File ▸ Open Recent + Dock
        // menu). Every open path — menu, CLI, Finder, Services, intents — ends
        // up here, so this is the one central place to note it.
        NSDocumentController.shared.noteNewRecentDocumentURL(rootURL)
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

    /// Opens a new, empty, untitled document as a tab in the active pane.
    func newUntitledDocument() {
        let document = OpenDocument()
        layout.activePane?.open(document)
    }

    func saveActiveDocument() async {
        guard let document = activeDocument else { return }
        if document.isUntitled {
            saveAs(document)
        } else {
            await document.save()
        }
    }

    /// Runs a Save panel for a document, writes its text, and assigns the chosen
    /// URL *in place* — the same document (and its tab / editor) is kept, now
    /// backed by a file. Caches it and re-highlights via the URL change.
    /// Returns whether it was saved.
    @discardableResult
    func saveAs(_ document: OpenDocument) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.name
        panel.directoryURL = document.url?.deletingLastPathComponent()
            ?? (isDirectory ? rootURL : rootURL.deletingLastPathComponent())
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try document.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        document.assignURL(url)
        document.isDirty = false
        documentCache[url] = document
        // Keep the pane's selection on this same document (its id is unchanged).
        Task { await reloadDirectory(at: url.deletingLastPathComponent()) }
        return true
    }

    func saveActiveDocumentAs() {
        guard let document = activeDocument else { return }
        saveAs(document)
    }

    func closeActiveTab() {
        guard let pane = layout.activePane, let document = pane.selectedDocument else { return }
        requestCloseTab(document, in: pane)
    }

    /// Closes a tab, prompting to save first (in a window-attached sheet) if the
    /// document has unsaved changes and isn't still open in another pane.
    func requestCloseTab(_ document: OpenDocument, in pane: EditorPane) {
        closeTabResolving(document, in: pane) { _ in }
    }

    /// Closes a tab, prompting to save first (as a sheet) if the document has
    /// unsaved changes and isn't still open in another pane. Calls `completion`
    /// with `true` if the tab closed (or nothing needed saving), `false` if the
    /// user cancelled — so bulk closes can chain and stop on cancel.
    private func closeTabResolving(
        _ document: OpenDocument,
        in pane: EditorPane,
        completion: @escaping (Bool) -> Void
    ) {
        guard pane.tabDocuments.contains(where: { $0.id == document.id }) else {
            completion(true)
            return
        }
        guard document.isDirty && !isOpenElsewhere(document, excluding: pane),
              let window = window ?? NSApp.keyWindow else {
            closeTab(document, in: pane)
            completion(true)
            return
        }

        let alert = makeSaveAlert(
            message: "Do you want to save the changes you made to “\(document.name)”?",
            informative: "Your changes will be lost if you don’t save them."
        )
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(false); return }
            switch response {
            case .alertFirstButtonReturn: // Save
                if document.isUntitled {
                    if self.saveAs(document) {
                        self.closeTab(document, in: pane)
                        completion(true)
                    } else {
                        completion(false)
                    }
                } else {
                    Task {
                        if await document.save() {
                            self.closeTab(document, in: pane)
                            completion(true)
                        } else {
                            completion(false)
                        }
                    }
                }
            case .alertThirdButtonReturn: // Don't Save
                self.discardDocument(document)
                self.closeTab(document, in: pane)
                completion(true)
            default: // Cancel
                completion(false)
            }
        }
    }

    /// Requests closing a sequence of tabs in a pane, one at a time (each dirty
    /// document gets its own sheet). Stops if the user cancels.
    private func requestCloseTabs(
        _ documents: [OpenDocument],
        in pane: EditorPane,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard let first = documents.first else { completion(true); return }
        let rest = Array(documents.dropFirst())
        closeTabResolving(first, in: pane) { [weak self] closed in
            guard closed, let self else { completion(false); return }
            self.requestCloseTabs(rest, in: pane, completion: completion)
        }
    }

    /// Closes the active pane, prompting for any of its dirty solo tabs first.
    func closeActivePane() {
        guard layout.panes.count > 1, let pane = layout.activePane else { return }
        requestCloseTabs(pane.tabDocuments, in: pane) { [weak self] allClosed in
            guard allClosed, let self else { return }
            self.layout.closePane(pane.id)
        }
    }

    private func closeTab(_ document: OpenDocument, in pane: EditorPane) {
        pane.close(document)
        if pane.tabDocuments.isEmpty && layout.panes.count > 1 {
            layout.closePane(pane.id)
        }
    }

    private func isOpenElsewhere(_ document: OpenDocument, excluding pane: EditorPane) -> Bool {
        layout.panes.contains { $0.id != pane.id && $0.tabDocuments.contains { $0.id == document.id } }
    }

    /// Drops a document's buffer so its unsaved edits are truly discarded; a
    /// later reopen reads fresh from disk. Untitled buffers just vanish.
    private func discardDocument(_ document: OpenDocument) {
        if let url = document.url {
            documentCache.removeValue(forKey: url)
        }
    }

    func splitActiveEditor() {
        layout.splitActive()
    }

    /// Moves selection to an adjacent tab in the active pane, wrapping around.
    func selectAdjacentTab(offset: Int) {
        guard let pane = layout.activePane,
              !pane.tabDocuments.isEmpty,
              let current = pane.tabDocuments.firstIndex(where: { $0.id == pane.selectedID })
        else { return }
        let count = pane.tabDocuments.count
        let next = (current + offset + count) % count
        pane.selectedID = pane.tabDocuments[next].id
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

    /// Distinct documents with unsaved edits that are currently open in a tab.
    var dirtyDocuments: [OpenDocument] {
        var seen = Set<OpenDocument.ID>()
        var result: [OpenDocument] = []
        for pane in layout.panes {
            for document in pane.tabDocuments where document.isDirty && !seen.contains(document.id) {
                seen.insert(document.id)
                result.append(document)
            }
        }
        return result
    }

    /// Called from the window's close guard. Returns `true` if the window may
    /// close immediately (no unsaved changes). Returns `false` if we've taken
    /// over: either presenting a save sheet that will call `proceed()` once the
    /// user resolves it, or (re-entrantly) declining to prompt twice.
    func requestWindowClose(proceed: @escaping () -> Void) -> Bool {
        let dirty = dirtyDocuments
        guard !dirty.isEmpty else { return true }
        guard !isPresentingCloseSheet, let window = window ?? NSApp.keyWindow else { return false }

        isPresentingCloseSheet = true
        let message = dirty.count == 1
            ? "Do you want to save the changes you made to “\(dirty[0].name)”?"
            : "You have \(dirty.count) documents with unsaved changes."
        let alert = makeSaveAlert(message: message, informative: "Your changes will be lost if you don’t save them.")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPresentingCloseSheet = false
            switch response {
            case .alertFirstButtonReturn: // Save
                Task { @MainActor in
                    await self.saveAllForClose(dirty)
                    proceed()
                }
            case .alertThirdButtonReturn: // Don't Save
                proceed()
            default: // Cancel
                break
            }
        }
        return false
    }

    /// Saves every dirty document before the window closes, routing untitled
    /// buffers through a Save panel.
    private func saveAllForClose(_ dirty: [OpenDocument]) async {
        for document in dirty {
            if document.isUntitled {
                _ = saveAs(document)
            } else {
                await document.save()
            }
        }
    }

    /// Builds the standard Save / Cancel / Don't Save alert.
    private func makeSaveAlert(message: String, informative: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        return alert
    }
}
