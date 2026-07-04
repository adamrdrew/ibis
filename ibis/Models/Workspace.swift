import Foundation
import Observation
import AppKit

/// The live state for a single window: the opened folder (or file), its file
/// tree, and (in later phases) open tabs and pane layout.
@Observable
@MainActor
final class Workspace {
    /// Weakly-held registry of every live workspace, so app-wide operations
    /// (notably quit confirmation) can reach each open window's documents.
    @ObservationIgnored private static var registry: [WeakWorkspaceBox] = []

    /// All currently-live workspaces (closed windows drop out automatically).
    static var all: [Workspace] {
        registry.compactMap(\.value)
    }

    let rootURL: URL
    let isDirectory: Bool
    let rootNode: FileNode
    let layout = EditorLayout()
    let terminal: TerminalDock
    let git: GitStatusModel
    let projectConfig: ProjectConfig

    /// The folder used for trust, terminals, git, and project config (the root
    /// itself for a folder workspace, or a single file's parent folder).
    let projectRoot: URL

    /// Whether the user has trusted this folder. Until then, Ibis never applies
    /// the folder's `.ibis.json` environment or exposes its actions, so merely
    /// opening an untrusted repo can't run code from it.
    private(set) var isTrusted = false

    /// True when a trust decision is pending (the folder ships executable
    /// `.ibis.json` content and the user hasn't decided yet). Drives a prompt.
    var trustPromptNeeded = false

    /// Set when an agent launch was requested for a folder that wasn't yet
    /// trusted; performed once the user grants trust.
    var pendingAgentLaunch = false

    /// Set by the Project Settings menu command to open the settings sheet.
    var projectSettingsRequested = false

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

    /// Asks the file browser to expand to and select a URL (MCP `reveal_in_tree`).
    var onRevealInTree: ((URL) -> Void)?

    func requestRevealInTree(_ url: URL) {
        onRevealInTree?(url)
    }

    /// An agent-proposed edit awaiting the human's review (MCP `propose_edit`).
    /// WorkspaceView presents a diff sheet while this is set.
    var pendingDiff: DiffProposal?

    /// Resumed with the human's decision when the diff sheet is dismissed.
    @ObservationIgnored private var pendingDiffDecision: CheckedContinuation<Bool, Never>?

    /// Presents `proposal` and suspends until the human applies or discards it.
    func awaitDiffDecision(_ proposal: DiffProposal) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingDiffDecision = continuation
            pendingDiff = proposal
        }
    }

    /// Resolves the pending diff review (from the sheet buttons or on close).
    func resolvePendingDiff(apply: Bool) {
        guard let continuation = pendingDiffDecision else { return }
        pendingDiffDecision = nil
        pendingDiff = nil
        continuation.resume(returning: apply)
    }

    /// Applies approved content to the file: into the open buffer (so the editor
    /// shows it and undo works), then saved to disk.
    func applyProposedEdit(url: URL, content: String) async {
        let document = document(for: url)
        await document.loadIfNeeded()
        document.text = content
        document.isDirty = true
        layout.activePane?.open(document)
        await document.save()
    }

    /// The already-open document for a URL, if any (without creating one).
    func openedDocument(for url: URL) -> OpenDocument? {
        documentCache[url]
    }

    /// The hosting window, so unsaved-changes confirmations can attach as sheets.
    /// `@ObservationIgnored` because it's assigned from a view-backing
    /// representable during the update pass; observing it would risk a
    /// dependency cycle, and no view needs to react to it.
    @ObservationIgnored weak var window: NSWindow?

    /// The editor in this window that most recently had focus, so the MCP
    /// `get_selection` tool reads the selection from the right window.
    @ObservationIgnored weak var focusedEditor: NSTextView?

    /// True while a window-close save sheet is up, to avoid presenting a second.
    @ObservationIgnored private var isPresentingCloseSheet = false

    /// Whether the opened folder is empty (loaded, no visible children). Updated
    /// only outside the file browser's layout pass — never a live read of
    /// `rootNode.children`, which the outline view mutates *during* layout and
    /// would form a fatal dependency cycle with the sidebar's empty-state hint.
    private(set) var rootIsEmpty = false

    init(rootURL: URL, isDirectory: Bool) {
        self.rootURL = rootURL
        self.isDirectory = isDirectory
        self.access = SecurityScopedAccess(url: rootURL)
        self.rootNode = FileNode(url: rootURL, isDirectory: isDirectory)
        // Terminals and Git status use the folder (or a single file's folder).
        let terminalRoot = isDirectory ? rootURL : rootURL.deletingLastPathComponent()
        self.terminal = TerminalDock(workingDirectory: terminalRoot)
        self.git = GitStatusModel(root: terminalRoot)
        self.projectConfig = ProjectConfig(root: terminalRoot)
        self.projectRoot = terminalRoot
        // Only apply the project environment if the folder is already trusted.
        let trusted = WorkspaceTrust.isTrusted(terminalRoot)
        self.isTrusted = trusted
        self.terminal.projectEnv = trusted ? projectConfig.environment : [:]
        // Prompt for trust when the folder ships executable config and the user
        // hasn't decided yet.
        self.trustPromptNeeded = !trusted
            && !WorkspaceTrust.hasDecision(terminalRoot)
            && projectConfig.hasExecutableContent

        if isDirectory {
            watcher = FileSystemWatcher(path: rootURL.path(percentEncoded: false)) { [weak self] paths in
                Task { @MainActor in
                    await self?.handleFileSystemChanges(paths)
                }
            }
        }

        git.refresh()

        Self.registry.removeAll { $0.value == nil }
        Self.registry.append(WeakWorkspaceBox(self))

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
            if node === rootNode { refreshRootEmptiness() }
        }
    }

    /// Reloads the loaded directory nodes affected by filesystem changes.
    private func handleFileSystemChanges(_ paths: [String]) async {
        // Any change on disk (including inside .git — commits, branch switches,
        // staging) may affect Git status, so refresh it too.
        git.refresh()

        // Keep open buffers honest about changes made outside Ibis.
        await reconcileOpenDocuments()

        var reloaded = Set<URL>()
        for path in paths {
            let directory = URL(filePath: path).standardizedFileURL
            guard !reloaded.contains(directory),
                  let node = loadedDirectoryNode(matching: directory) else { continue }
            reloaded.insert(directory)
            await node.reloadChildrenMerging()
            onDirectoryReloaded?(node)
            if node === rootNode { refreshRootEmptiness() }
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

    /// Recomputes `rootIsEmpty` from the (already-loaded) root children. Call
    /// only from outside the outline view's layout — after an async load or a
    /// filesystem reload — so it never races the outline's in-layout child load.
    func refreshRootEmptiness() {
        rootIsEmpty = isDirectory && rootNode.isLoaded && (rootNode.children?.isEmpty ?? false)
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

    // MARK: - Layout persistence & restoration

    /// A cheap value that changes whenever the persisted layout would change
    /// (pane contents, selection, active pane). WorkspaceView observes it to
    /// know when to persist.
    var layoutFingerprint: String {
        var parts: [String] = []
        for pane in layout.panes {
            let paths = pane.tabDocuments.compactMap { $0.url?.path(percentEncoded: false) }
            let selected = pane.selectedDocument?.url?.path(percentEncoded: false) ?? ""
            parts.append(paths.joined(separator: "|") + ">" + selected)
        }
        let activeIndex = layout.panes.firstIndex { $0.id == layout.activePaneID } ?? 0
        parts.append("active=\(activeIndex)")
        return parts.joined(separator: ";")
    }

    /// Snapshots the current layout to the store (directory workspaces only;
    /// untitled documents, having no path, are skipped).
    func persistLayoutState() {
        guard isDirectory else { return }
        var paneFilePaths: [[String]] = []
        var selected: [Int] = []
        for pane in layout.panes {
            let paths = pane.tabDocuments.compactMap { $0.url?.path(percentEncoded: false) }
            paneFilePaths.append(paths)
            if let selectedPath = pane.selectedDocument?.url?.path(percentEncoded: false),
               let index = paths.firstIndex(of: selectedPath) {
                selected.append(index)
            } else {
                selected.append(-1)
            }
        }
        let activeIndex = layout.panes.firstIndex { $0.id == layout.activePaneID } ?? 0
        WorkspaceStateStore.save(
            PersistedWorkspaceState(
                paneFilePaths: paneFilePaths,
                selectedTabPerPane: selected,
                activePaneIndex: activeIndex,
                savedAt: Date()
            ),
            for: rootURL
        )
    }

    /// Restores the persisted tabs/panes/selection into a fresh layout. Missing
    /// files are silently skipped; if everything is gone, the empty state stays.
    func restorePersistedLayout() async {
        guard isDirectory,
              let state = WorkspaceStateStore.load(for: rootURL),
              layout.panes.count == 1, layout.panes[0].tabDocuments.isEmpty else { return }

        var panes: [EditorPane] = []
        for (paneIndex, paths) in state.paneFilePaths.enumerated() {
            let pane = paneIndex == 0 ? layout.panes[0] : EditorPane()
            for path in paths {
                let url = URL(filePath: path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let document = document(for: url)
                await document.loadIfNeeded()
                pane.open(document)
            }
            let selectedIndex = paneIndex < state.selectedTabPerPane.count ? state.selectedTabPerPane[paneIndex] : -1
            if selectedIndex >= 0, selectedIndex < pane.tabDocuments.count {
                pane.selectedID = pane.tabDocuments[selectedIndex].id
            }
            panes.append(pane)
        }

        panes = panes.filter { !$0.tabDocuments.isEmpty }
        guard !panes.isEmpty else { return }
        layout.panes = panes
        let activeIndex = min(max(0, state.activePaneIndex), panes.count - 1)
        layout.activePaneID = panes[activeIndex].id
    }

    // MARK: - Menu actions (operate on the active pane / document)

    var activeDocument: OpenDocument? {
        layout.activePane?.selectedDocument
    }

    /// Set by the Go to Line command to trigger the prompt in the editor UI.
    var goToLineRequested = false

    /// Selects and reveals the given 1-based line in the active document, reusing
    /// the same `pendingSelection` mechanism as opening a search result.
    func goToLine(_ requested: Int) {
        guard let document = activeDocument else { return }
        let ns = document.text as NSString
        guard ns.length > 0 else {
            document.pendingSelection = NSRange(location: 0, length: 0)
            return
        }
        let target = max(1, requested)
        var line = 1
        var loc = 0
        while line < target && loc < ns.length {
            loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            line += 1
        }
        document.pendingSelection = ns.lineRange(for: NSRange(location: min(loc, ns.length - 1), length: 0))
    }

    /// Opens (or focuses) the file at `url` as a tab in the active pane. Used by
    /// a file-browser click, which must reopen a file even when its row is
    /// already selected (e.g. after its tab was closed).
    func openDocument(at url: URL) {
        let document = document(for: url)
        Task {
            await document.loadIfNeeded()
            layout.activePane?.open(document)
        }
    }

    /// Opens a new, empty, untitled document as a tab in the active pane.
    func newUntitledDocument() {
        let document = OpenDocument()
        layout.activePane?.open(document)
    }

    func saveActiveDocument() async {
        guard let document = activeDocument else { return }
        if document.isUntitled {
            saveAs(document) // presents its own error on failure
        } else {
            let saved = await document.save()
            if !saved {
                presentError("Couldn’t save “\(document.name)”. Check that the file is writable and the volume has space.")
            }
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
            try document.text.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
        } catch {
            presentError("Couldn’t save “\(url.lastPathComponent)”: \(error.localizedDescription)")
            return false
        }
        document.assignURL(url)
        document.isDirty = false
        documentCache[url] = document
        // Drop any stale key the document was previously cached under, so its old
        // URL doesn't keep returning this now-retargeted document.
        rekeyDocumentCache()
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

    /// Closes every tab in a pane except the given one (dirty-safe, stops on
    /// cancel).
    func requestCloseOtherTabs(keeping document: OpenDocument, in pane: EditorPane) {
        let others = pane.tabDocuments.filter { $0.id != document.id }
        requestCloseTabs(others, in: pane)
    }

    /// Closes every tab in a pane positioned after the given one.
    func requestCloseTabs(after document: OpenDocument, in pane: EditorPane) {
        guard let index = pane.tabDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        let following = Array(pane.tabDocuments[(index + 1)...])
        requestCloseTabs(following, in: pane)
    }

    /// Closes the active pane, prompting for any of its dirty solo tabs first.
    func closeActivePane() {
        guard let pane = layout.activePane else { return }
        requestClosePane(pane)
    }

    /// Closes a specific pane, prompting to save any of its dirty solo tabs first
    /// (a document still open in another pane closes without a prompt). Routes
    /// through the guarded close path so the pane-header × can't silently discard
    /// unsaved edits.
    func requestClosePane(_ pane: EditorPane) {
        guard layout.panes.count > 1 else { return }
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

    // MARK: - Keeping open documents in sync with the filesystem

    /// After a file/folder is renamed or moved on disk, re-point any open
    /// documents at their new location (directories move their descendants too)
    /// and re-key the cache. Without this, a later ⌘S would recreate the file at
    /// its old path and the edits would be lost. Copies (not moves) are ignored.
    func relocateOpenDocuments(from oldURL: URL, to newURL: URL) {
        let oldPath = oldURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        var changed = false
        for document in documentCache.values {
            guard let docPath = document.url?.standardizedFileURL.path else { continue }
            if docPath == oldPath {
                document.assignURL(newURL.standardizedFileURL)
                changed = true
            } else if docPath.hasPrefix(oldPath + "/") {
                let moved = URL(filePath: newPath + docPath.dropFirst(oldPath.count))
                document.assignURL(moved)
                changed = true
            }
        }
        if changed { rekeyDocumentCache() }
    }

    /// Rebuilds the cache so every document is keyed by its *current* URL,
    /// dropping stale keys left behind by a Save As or a rename/move.
    private func rekeyDocumentCache() {
        var rebuilt: [URL: OpenDocument] = [:]
        for document in documentCache.values {
            if let url = document.url { rebuilt[url] = document }
        }
        documentCache = rebuilt
    }

    /// Reconciles every open document with disk after external filesystem
    /// changes: clean buffers reload, dirty buffers get a "changed on disk" flag.
    private func reconcileOpenDocuments() async {
        for document in documentCache.values {
            await document.reconcileWithDisk()
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

    /// Reverts the active document to its saved contents, after a sheet
    /// confirmation.
    func revertActiveDocument() {
        guard let document = activeDocument, document.isDirty, document.url != nil,
              let window = window ?? NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Do you want to revert to the last saved version of “\(document.name)”?"
        alert.informativeText = "Your current changes will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                Task { await document.revertToSaved() }
            }
        }
    }

    func revealActiveInFinder() {
        guard let url = activeDocument?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Prints the active document via a paginating text view built from its
    /// current text (independent of which editor, if any, has focus).
    func printActiveDocument() {
        guard let document = activeDocument, !document.isBinary else { return }
        let printInfo = NSPrintInfo.shared
        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: max(1, width), height: printInfo.paperSize.height))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.string = document.text
        textView.font = NSFont(name: "Menlo", size: 11)
            ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.jobTitle = document.name
        if let window = window ?? NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: - Trust

    /// The actions Ibis will expose/run — none until the folder is trusted.
    var availableActions: [ProjectConfig.Action] {
        isTrusted ? projectConfig.runnableActions : []
    }

    /// Records the user's trust decision. Granting trust applies the project
    /// environment and performs any agent launch that was waiting on it.
    func resolveTrust(_ trusted: Bool) {
        WorkspaceTrust.setTrusted(trusted, for: projectRoot)
        isTrusted = trusted
        trustPromptNeeded = false
        applyProjectEnv()
    }

    // MARK: - Project actions

    /// Runs a project action in the shared Run terminal tab (env refreshed).
    /// No-op for an untrusted folder (the UI hides actions there anyway).
    func runProjectAction(_ action: ProjectConfig.Action) {
        guard isTrusted else { return }
        terminal.projectEnv = projectConfig.environment
        terminal.runAction(name: action.name, command: action.command)
    }

    /// Whether a project action is currently running (for the toolbar's play/stop).
    var isActionRunning: Bool { terminal.isActionRunning }

    /// Stops the running project action.
    func stopProjectAction() {
        terminal.stopAction()
    }

    /// Re-applies project env to the dock after settings change (affects new
    /// sessions; already-running shells keep their environment). Untrusted
    /// folders contribute no environment.
    func applyProjectEnv() {
        terminal.projectEnv = isTrusted ? projectConfig.environment : [:]
    }

    /// Persists edits made in Project Settings, then reconciles trust: a trusted
    /// folder gets its env applied immediately; an as-yet-undecided folder whose
    /// config now carries executable content raises the trust prompt, so the
    /// user's own env/actions aren't silently withheld with no way to enable them.
    func commitProjectSettings() {
        try? projectConfig.save()
        if isTrusted {
            applyProjectEnv()
        } else if projectConfig.hasExecutableContent
            && !WorkspaceTrust.hasDecision(projectRoot) {
            trustPromptNeeded = true
        }
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
        presentCloseConfirmation(dirty, on: window) { [weak self] outcome in
            self?.isPresentingCloseSheet = false
            switch outcome {
            case .discarded, .saved:
                proceed()
            case .cancelled, .saveFailed:
                break // keep the window open
            }
        }
        return false
    }

    /// Confirms and (optionally) saves this window's dirty documents when the app
    /// is quitting. Returns `true` if the app may proceed to quit this window
    /// (saved or discarded), `false` if the user cancelled or a save failed.
    func confirmCloseForQuit() async -> Bool {
        let dirty = dirtyDocuments
        guard !dirty.isEmpty else { return true }
        guard let window = window ?? NSApp.keyWindow else { return true }
        // Bring the window forward so the user sees which one they're answering.
        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            presentCloseConfirmation(dirty, on: window) { outcome in
                switch outcome {
                case .saved, .discarded: continuation.resume(returning: true)
                case .cancelled, .saveFailed: continuation.resume(returning: false)
                }
            }
        }
    }

    private enum CloseOutcome { case saved, discarded, cancelled, saveFailed }

    /// Presents the Save / Cancel / Don't Save sheet and, on Save, writes every
    /// dirty document — reporting a failure instead of pretending it succeeded.
    private func presentCloseConfirmation(
        _ dirty: [OpenDocument],
        on window: NSWindow,
        completion: @escaping (CloseOutcome) -> Void
    ) {
        let message = dirty.count == 1
            ? "Do you want to save the changes you made to “\(dirty[0].name)”?"
            : "You have \(dirty.count) documents with unsaved changes."
        let alert = makeSaveAlert(message: message, informative: "Your changes will be lost if you don’t save them.")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(.cancelled); return }
            switch response {
            case .alertFirstButtonReturn: // Save
                Task { @MainActor in
                    if await self.saveAllForClose(dirty) {
                        completion(.saved)
                    } else {
                        self.presentError("Some changes couldn’t be saved, so the window stayed open.")
                        completion(.saveFailed)
                    }
                }
            case .alertThirdButtonReturn: // Don't Save
                completion(.discarded)
            default: // Cancel
                completion(.cancelled)
            }
        }
    }

    /// Saves every dirty document before the window closes, routing untitled
    /// buffers through a Save panel. Returns `true` only if *all* saves
    /// succeeded (a cancelled Save panel or a write failure returns `false`), so
    /// the caller can keep the window open rather than lose the edits.
    private func saveAllForClose(_ dirty: [OpenDocument]) async -> Bool {
        var allSucceeded = true
        for document in dirty {
            if document.isUntitled {
                if !saveAs(document) { allSucceeded = false }
            } else {
                let saved = await document.save()
                if !saved { allSucceeded = false }
            }
        }
        return allSucceeded
    }

    /// Presents a non-blocking error alert as a sheet on this window.
    func presentError(_ message: String) {
        guard let window = window ?? NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
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

/// Weak reference to a workspace, for the live-workspace registry.
private struct WeakWorkspaceBox {
    weak var value: Workspace?
    init(_ value: Workspace) { self.value = value }
}
