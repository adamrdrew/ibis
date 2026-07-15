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

    /// The app settings, set once by `WorkspaceView`. Held so deep AppKit call
    /// sites (notably "Send to Agent" from a context menu, which has no
    /// environment) can launch the configured agent. Weak — settings is a single
    /// app-lifetime object owned by `IbisApp`.
    @ObservationIgnored weak var settings: AppSettings?

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
    /// nil while the browser isn't mounted (Search sidebar showing).
    var onRevealInTree: ((URL) -> Void)?

    /// A reveal that arrived while the file browser wasn't mounted; the browser
    /// consumes it when it (re)connects, so the request isn't silently dropped.
    var pendingReveal: URL?

    func requestRevealInTree(_ url: URL) {
        if let onRevealInTree {
            onRevealInTree(url)
        } else {
            pendingReveal = url
        }
    }

    /// An agent-proposed edit awaiting the human's review (MCP `propose_edit`).
    /// WorkspaceView presents a diff sheet while this is set.
    var pendingDiff: DiffProposal?

    /// Resumed with the human's decision when the diff sheet is dismissed.
    @ObservationIgnored private var pendingDiffDecision: CheckedContinuation<Bool, Never>?

    /// Presents `proposal` and suspends until the human applies or discards it.
    func awaitDiffDecision(_ proposal: DiffProposal) async -> Bool {
        await withCheckedContinuation { continuation in
            // If a decision is somehow already pending, resolve it as declined
            // rather than dropping its continuation — an abandoned
            // CheckedContinuation would hang that MCP call forever and trip a
            // runtime check.
            if let existing = pendingDiffDecision {
                pendingDiffDecision = nil
                existing.resume(returning: false)
            }
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
    /// shows it and undo works), then saved to disk. `expectedCurrent` is the
    /// content the approved diff was computed against; if the document no longer
    /// matches it, nothing is applied. A non-editable document is left untouched.
    enum ApplyEditOutcome {
        case applied
        /// The buffer no longer matches the content the approved diff was
        /// computed against (the user typed, a reload landed, another agent
        /// wrote it) — applying would clobber changes the human never reviewed.
        case staleContent
        case notWritable
        /// The buffer took the approved content but the write to disk failed
        /// (file went read-only, volume full). The editor shows the change as
        /// unsaved; disk is untouched — distinct from `notWritable`, where
        /// nothing changed anywhere.
        case saveFailed
    }

    func applyProposedEdit(url: URL, content: String, replacing expectedCurrent: String) async -> ApplyEditOutcome {
        // A proposal against a file that doesn't exist (and isn't an open buffer)
        // is a *creation*: the human just approved an all-added diff, so write
        // the file and open it. Routing it through `loadIfNeeded` instead would
        // fail after approval with a misleading "read-only or binary" error and
        // cache a permanently broken document for the tab.
        if openedDocument(for: url) == nil,
           !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            guard expectedCurrent.isEmpty else { return .staleContent }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return .notWritable
            }
            let document = document(for: url)
            await document.loadIfNeeded()
            layout.activePane?.open(document)
            await reloadDirectory(at: url.deletingLastPathComponent())
            return .applied
        }

        let document = document(for: url)
        await document.loadIfNeeded()
        guard document.isEditable else { return .notWritable }
        guard document.text == expectedCurrent else { return .staleContent }
        document.text = content
        document.isDirty = true
        layout.activePane?.open(document)
        return await document.save() ? .applied : .saveFailed
    }

    /// The already-open document for a URL, if any (without creating one).
    func openedDocument(for url: URL) -> OpenDocument? {
        documentCache[cacheKey(url)]
    }

    /// The canonical cache key for a URL: symlinks resolved, path standardized.
    /// One on-disk file must map to one buffer no matter how its path is spelled
    /// (`/tmp` vs `/private/tmp`, a symlinked root, an agent-supplied realpath) —
    /// two divergent buffers for the same file would silently clobber each other,
    /// whichever saved last.
    private func cacheKey(_ url: URL) -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        // `resolvingSymlinksInPath` only canonicalizes components that exist on
        // disk, so when the leaf is gone (a rename/move in flight) a symlinked
        // *parent* stays unresolved and two spellings of the same location no
        // longer collapse — e.g. `relocateOpenDocuments` would miss re-pointing a
        // moved buffer under a symlinked root, and a later ⌘S would recreate the
        // file at its old path. Resolve the surviving parent and re-append the
        // leaf name so the key is stable regardless of whether the leaf exists.
        if FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)) {
            return resolved
        }
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent)
            .standardizedFileURL
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

        // Watch the folder — or, for a single-file workspace, its enclosing
        // folder — so external changes still reconcile open buffers and refresh
        // Git status. Without a watcher, a file opened directly never noticed a
        // `git checkout` (even one run in its own integrated terminal) and ⌘S
        // would silently clobber the on-disk change.
        watcher = FileSystemWatcher(path: (isDirectory ? rootURL : terminalRoot).path(percentEncoded: false)) { [weak self] events in
            Task { @MainActor in
                await self?.handleFileSystemChanges(events)
            }
        }

        git.refresh()

        // MCP configs written by builds that predate the token-file hardening
        // may still be world-readable and un-gitignored; re-assert both for
        // this project (no-op unless a token-bearing Ibis entry exists).
        let hardenRoot = terminalRoot
        Task.detached(priority: .utility) {
            MCPConfigWriter.hardenExistingConfigs(projectRoot: hardenRoot)
        }

        Self.registry.removeAll { $0.value == nil }
        Self.registry.append(WeakWorkspaceBox(self))

        // A terminal program asking for attention (OSC 9/777, or the bell as a
        // fallback) becomes a desktop notification when the session isn't the
        // one being looked at.
        terminal.onSessionNotification = { [weak self] session, title, body in
            self?.handleTerminalNotification(session, title: title, body: body)
        }
        terminal.onSessionBell = { [weak self] session in
            self?.handleTerminalBell(session)
        }

        // Record in the system's Recent Documents (File ▸ Open Recent + Dock
        // menu). Every open path — menu, CLI, Finder, Services, intents — ends
        // up here, so this is the one central place to note it. Skipped under
        // the test runner: unit tests construct throwaway workspaces by the
        // dozen and would flush the user's real recents.
        if NSClassFromString("XCTestCase") == nil {
            NSDocumentController.shared.noteNewRecentDocumentURL(rootURL)
        }
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
    private func handleFileSystemChanges(_ events: [FileSystemWatcher.Event]) async {
        // Any change on disk (including inside .git — commits, branch switches,
        // staging) may affect Git status, so refresh it too.
        git.refresh()

        // Keep open buffers honest about changes made outside Ibis.
        await reconcileOpenDocuments()

        var reloaded = Set<URL>()
        for event in events {
            let directory = URL(filePath: event.path).standardizedFileURL
            if event.mustScanSubDirs {
                // Coalesced/dropped events: everything below this path may have
                // changed, so refresh the whole loaded subtree — reloading just
                // the immediate children would leave every expanded descendant
                // directory stale until manually collapsed and re-expanded.
                await reloadLoadedSubtree(under: directory)
                continue
            }
            guard !reloaded.contains(directory),
                  let node = loadedDirectoryNode(matching: directory) else { continue }
            reloaded.insert(directory)
            await node.reloadChildrenMerging()
            onDirectoryReloaded?(node)
            if node === rootNode { refreshRootEmptiness() }
        }
    }

    /// Reloads every already-loaded directory at or below `directory`. A
    /// `MustScanSubDirs` path can also be an *ancestor* of the watch root (the
    /// kernel reports the deepest common parent it kept), so that case rescans
    /// from the root node.
    private func reloadLoadedSubtree(under directory: URL) async {
        let target = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = rootNode.url.resolvingSymlinksInPath().standardizedFileURL.path
        let start: FileNode?
        if rootPath == target || rootPath.hasPrefix(target + "/") {
            start = rootNode
        } else {
            start = loadedDirectoryNode(matching: directory)
        }
        guard let start, start.isDirectory else { return }

        var stack = [start]
        while let node = stack.popLast() {
            guard node.isLoaded else { continue }
            await node.reloadChildrenMerging()
            onDirectoryReloaded?(node)
            if node === rootNode { refreshRootEmptiness() }
            stack.append(contentsOf: (node.children ?? []).filter { $0.isDirectory && $0.isLoaded })
        }
    }

    /// Finds an already-loaded directory node whose URL matches, walking only
    /// loaded branches (unexpanded subtrees refresh themselves when opened).
    private func loadedDirectoryNode(matching directory: URL) -> FileNode? {
        // Compare canonical (symlink-resolved) paths, for the same reason as
        // `cacheKey`: FSEvents delivers realpath'd paths, while node URLs keep
        // the spelling the workspace was opened with. With a symlinked root
        // (`ibis ~/proj` → /Volumes/Code/proj) no event would ever match a node
        // and the tree would never live-refresh.
        let target = directory.resolvingSymlinksInPath().standardizedFileURL.path
        func search(_ node: FileNode) -> FileNode? {
            if node.isDirectory, node.isLoaded,
               node.url.resolvingSymlinksInPath().standardizedFileURL.path == target {
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

    /// The desktop-notification title for pings from this project's agent —
    /// "Claude in ibis" — naming both the agent and the project, so with
    /// several Ibis windows running agents the notification says which one
    /// wants the human back.
    var agentNotificationTitle: String {
        "\(settings?.agentName ?? "Agent") in \(displayName)"
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
        let key = cacheKey(url)
        if let existing = documentCache[key] {
            return existing
        }
        let document = OpenDocument(url: url)
        documentCache[key] = document
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
        // Terminal dock: recreate a persist when the set of tabs, their roles,
        // the active tab, or dock visibility change. Titles are deliberately
        // excluded — an agent rewrites its tab title constantly and would
        // otherwise churn the store on every keystroke of output.
        for session in terminal.persistableSessions {
            parts.append("t:\(session.role):\(session.id)")
        }
        parts.append("term=\(terminal.activePersistableIndex):\(terminal.isVisible)")
        return parts.joined(separator: ";")
    }

    /// True once the window has finished restoring its persisted layout; a
    /// persist can't run before then. Without this gate, assigning the fresh
    /// (empty) workspace fires `WorkspaceView`'s `layoutFingerprint` `onChange`
    /// and saves an empty snapshot *over* the real saved state before
    /// `restorePersistedLayout` gets to read it — losing every tab and terminal.
    /// Flipped only by `finishRestoration()`, which also flushes once.
    @ObservationIgnored private(set) var restorationComplete = false

    /// Marks restoration finished and, if anything actually restored, writes the
    /// current state once. The flush matters: persistence triggers are
    /// edge-triggered (`onChange` of the fingerprint), so anything the user
    /// changed *while* restore was still running fired only gated no-op
    /// persists — without writing now, that state would be lost unless something
    /// changed again later.
    ///
    /// The empty-content guard is the safety valve: if restore produced nothing
    /// (its files are temporarily missing, its data was already cleared, …), we
    /// must NOT write a blank snapshot over a saved layout — merely opening a
    /// window would otherwise erase it. A genuinely-empty workspace has nothing
    /// to lose, and real user actions after this persist normally.
    func finishRestoration() {
        restorationComplete = true
        guard hasPersistableLayout else { return }
        persistLayoutState()
    }

    /// Whether the current layout holds anything worth persisting: at least one
    /// open editor tab or one persistable terminal tab (shell/agent).
    var hasPersistableLayout: Bool {
        layout.panes.contains { !$0.tabDocuments.isEmpty } || !terminal.persistableSessions.isEmpty
    }

    /// Each editor pane's share of the editor width (one entry per pane, summing
    /// to ~1), included in every persisted snapshot. `EditorAreaView` reads this
    /// to lay the panes out and writes it as a divider is dragged, so it's
    /// observed — a restore or a drag must re-lay the split.
    var paneWidthFractions: [Double]?

    func persistLayoutState() {
        guard isDirectory, restorationComplete else { return }
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
                savedAt: Date(),
                terminal: terminalSnapshot(),
                paneWidthFractions: paneWidthFractions
            ),
            for: rootURL
        )
    }

    /// Snapshots the terminal dock for persistence: every tab except the reusable
    /// `.run` project-action tab, the active tab's index, and dock visibility.
    private func terminalSnapshot() -> PersistedTerminalDock {
        let sessions = terminal.persistableSessions.map { session in
            PersistedTerminalSession(role: session.role, title: session.title)
        }
        return PersistedTerminalDock(
            sessions: sessions,
            activeSessionIndex: terminal.activePersistableIndex,
            isVisible: terminal.isVisible,
            height: Double(terminal.dockHeight),
            width: Double(terminal.dockWidth)
        )
    }

    /// Restores the whole persisted session — editor layout, then the terminal
    /// dock on top — and opens the persistence gate. The single entry point a
    /// window calls after loading the file tree, so any surface that
    /// materializes a workspace gets identical restore behavior.
    func restoreSession(settings: AppSettings) async {
        guard !restorationComplete else { return }
        if isDirectory {
            let state = WorkspaceStateStore.load(for: rootURL)
            await restorePersistedLayout(state)
            if let dock = state?.terminal {
                // Size first, and unconditionally: it must come back even for a
                // hidden or empty dock, whereas restoreTerminalDock bails when
                // there are no persisted tabs.
                if let height = dock.height { terminal.dockHeight = CGFloat(height) }
                if let width = dock.width { terminal.dockWidth = CGFloat(width) }
                restoreTerminalDock(dock, settings: settings)
            }
        }
        finishRestoration()
    }

    /// Restores the persisted tabs/panes/selection into a fresh layout. Missing
    /// files are silently skipped; if everything is gone, the empty state stays.
    func restorePersistedLayout() async {
        await restorePersistedLayout(WorkspaceStateStore.load(for: rootURL))
    }

    private func restorePersistedLayout(_ state: PersistedWorkspaceState?) async {
        guard isDirectory,
              let state,
              layout.panes.count == 1, layout.panes[0].tabDocuments.isEmpty else { return }

        // Check tab existence off the main actor: with many persisted tabs on a
        // slow/network volume, per-tab synchronous stats would block the UI at
        // window open.
        let allPaths = state.paneFilePaths.flatMap(\.self)
        let existingPaths = await Task.detached(priority: .userInitiated) {
            Set(allPaths.filter { FileManager.default.fileExists(atPath: URL(filePath: $0).path) })
        }.value

        var panes: [EditorPane] = []
        for (paneIndex, paths) in state.paneFilePaths.enumerated() {
            let pane = paneIndex == 0 ? layout.panes[0] : EditorPane()
            for path in paths {
                guard existingPaths.contains(path) else { continue }
                let url = URL(filePath: path)
                let document = document(for: url)
                await document.loadIfNeeded()
                pane.open(document)
            }
            // Resolve the selection by *path*, not by index: missing files are
            // skipped above, so the persisted index no longer lines up with the
            // (compacted) surviving tabs and would select the wrong file.
            let selectedIndex = paneIndex < state.selectedTabPerPane.count ? state.selectedTabPerPane[paneIndex] : -1
            if selectedIndex >= 0, selectedIndex < paths.count {
                let selectedPath = URL(filePath: paths[selectedIndex]).path(percentEncoded: false)
                if let match = pane.tabDocuments.first(where: { $0.url?.path(percentEncoded: false) == selectedPath }) {
                    pane.selectedID = match.id
                }
            }
            panes.append(pane)
        }

        let surviving = panes.enumerated().filter { !$0.element.tabDocuments.isEmpty }
        guard !surviving.isEmpty else { return }
        layout.panes = surviving.map(\.element)
        // Remap the persisted active index through the filter: it indexes the
        // *original* pane list, so a pane dropped above it (all files missing)
        // would otherwise shift activation onto the wrong survivor.
        let requested = min(max(0, state.activePaneIndex), panes.count - 1)
        let activePosition = surviving.lastIndex { $0.offset <= requested } ?? 0
        layout.activePaneID = surviving[activePosition].element.id

        // Saved pane widths only make sense if every pane survived (missing
        // files can drop panes above); the splitter reads these fractions to lay
        // the restored panes out at their saved proportions.
        if let fractions = state.paneWidthFractions, fractions.count == surviving.count {
            paneWidthFractions = fractions
        }
    }

    /// Recreates the persisted terminal dock. Every persisted tab comes back —
    /// dropping one would let the next snapshot overwrite the store without it,
    /// silently losing the user's tab. Agent tabs restore
    /// regardless of folder trust: a persisted agent tab exists only because
    /// the user launched one here themselves (the trust gate exists for
    /// Shortcut/Siri launches into folders the user has never seen, which can't
    /// have a snapshot). The user may already have opened a terminal during the
    /// editor-restore awaits — their tabs are kept, stay selected, and the
    /// restored tabs are added alongside rather than being silently discarded.
    private func restoreTerminalDock(_ dock: PersistedTerminalDock, settings: AppSettings) {
        guard !dock.sessions.isEmpty else { return }
        let hadUserSessions = !terminal.sessions.isEmpty
        let userActiveID = terminal.activeSessionID

        var restored: [TerminalSession] = []
        for session in dock.sessions {
            if session.role == .agent {
                restored.append(restoreAgentTab(session, settings: settings))
            } else {
                restored.append(terminal.newSession(title: session.title, takeFocus: false))
            }
        }

        if hadUserSessions {
            // The user's freshly opened terminal keeps focus and dock state.
            terminal.activeSessionID = userActiveID
        } else {
            if dock.activeSessionIndex >= 0, dock.activeSessionIndex < restored.count {
                terminal.activeSessionID = restored[dock.activeSessionIndex].id
            }
            terminal.isVisible = dock.isVisible
        }
    }

    /// Restores one persisted agent tab. For Claude, the tab relaunches into
    /// the project's deterministic session (`MCPService.projectSessionID`) —
    /// resuming its conversation if a transcript exists on disk, creating it
    /// with `--session-id` if not (Claude only writes the transcript on the
    /// first message). The session has a single claimant, so only the first
    /// Claude tab launches; any further persisted agent tabs (from snapshots
    /// written before one-project-one-agent) come back as plain shells rather
    /// than fighting over it. A non-Claude agent relaunches fresh, and a tab
    /// with no agent configured comes back as an idle agent-role tab whose
    /// Restart reclaims the project session once an agent is configured.
    private func restoreAgentTab(_ session: PersistedTerminalSession, settings: AppSettings) -> TerminalSession {
        if settings.agentKind == .claude {
            guard agentTab == nil else {
                return terminal.newSession(title: session.title, takeFocus: false)
            }
            if let (command, resume) = MCPService.agentRelaunchCommand(
                settings: settings,
                sessionID: MCPService.projectSessionID(for: projectRoot),
                workingDirectory: projectRoot,
                mcpConfig: MCPService.claudeMCPConfig(for: self, settings: settings)
            ) {
                MCPService.bindAgent(to: self, settings: settings)
                let restored = terminal.newSession(
                    command: command, title: session.title, role: .agent, takeFocus: false
                )
                if resume { armResumeRecovery(for: restored, settings: settings) }
                return restored
            }
        } else if let command = MCPService.launchCommand(settings: settings) {
            MCPService.bindAgent(to: self, settings: settings)
            return terminal.newSession(
                command: command, title: session.title, role: .agent, takeFocus: false
            )
        }
        // No agent configured: preserve the tab and its role.
        return terminal.newSession(title: session.title, role: .agent, takeFocus: false)
    }

    /// Recovers a Claude tab whose `--resume` failed because the conversation
    /// no longer exists (`claude` prints "No conversation found" and exits 1
    /// within a second — e.g. Claude pruned the transcript): the tab relaunches
    /// behind a notice, re-pinned to the *same* deterministic project session
    /// id with `--session-id`, starting its conversation over. When the
    /// transcript still exists, a fast failure instead means claude rejected
    /// the resume ("already in use") while another instance finished shutting
    /// down, so the same resume is retried (bounded) after a pause. The handler
    /// disarms itself on the first exit it declines to act on, so a deliberate
    /// quit of a successfully resumed agent can't trigger a phantom relaunch
    /// later.
    private func armResumeRecovery(for session: TerminalSession, settings: AppSettings) {
        var resumeRetriesRemaining = 2
        session.onProcessExit = { [weak self, weak session] exitCode, ranFor in
            guard let self, let session else { return }
            let disarm = { session.onProcessExit = nil }
            guard ranFor < 15, (exitCode ?? 0) != 0 else { return disarm() }
            let sid = MCPService.projectSessionID(for: self.projectRoot)
            if MCPService.claudeSessionFileExists(sessionID: sid, workingDirectory: self.projectRoot) {
                // The conversation is real, so keep trying to resume it. The
                // "already in use" rejection lands within a couple of seconds
                // of launch; anything slower is the user quitting a
                // *successful* resume (Ctrl-C, declining claude's own trust
                // prompt) and must be left alone. Past the bounded retries, the
                // exited overlay's Restart re-runs the same resume manually.
                guard ranFor < 3, resumeRetriesRemaining > 0 else { return disarm() }
                resumeRetriesRemaining -= 1
                Task { @MainActor [weak session] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let session, !session.isRunning else { return }
                    session.relaunch(notice: "Previous \(settings.agentName) instance is still closing — retrying…")
                }
                return
            }
            disarm()
            guard let command = MCPService.launchCommand(
                settings: settings, sessionID: sid,
                mcpConfig: MCPService.claudeMCPConfig(for: self, settings: settings)
            ) else { return }
            MCPService.bindAgent(to: self, settings: settings)
            session.relaunch(
                notice: "Previous \(settings.agentName) conversation not found — starting it over.",
                command: command
            )
        }
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
        // `loc == length` means the walk ran off the end: the line range *at*
        // the end position resolves both cases — the trailing empty line of a
        // newline-terminated file (caret at the very end, `{length, 0}`) and a
        // past-EOF request in an unterminated file (the last real line). The
        // old `length - 1` clamp could never reach that empty last line.
        document.pendingSelection = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
    }

    /// Opens (or focuses) the file at `url` as a tab in the active pane. Used by
    /// a file-browser click, which must reopen a file even when its row is
    /// already selected (e.g. after its tab was closed).
    ///
    /// Opening this project's own `.ibis.json` is special-cased: it holds the
    /// project settings the GUI manages, so (per the user's remembered choice)
    /// it can open the Project Settings editor instead of the raw file.
    func openDocument(at url: URL) {
        if isProjectConfigFile(url) {
            handleProjectConfigOpen(at: url)
            return
        }
        openDocumentTab(at: url)
    }

    /// Opens `url` as an ordinary editor tab (the plain, non-special path).
    private func openDocumentTab(at url: URL) {
        let document = document(for: url)
        openTicket += 1
        let ticket = openTicket
        Task {
            await document.loadIfNeeded()
            // A newer open superseded this one while the file was still being
            // read (click large A, then small B: B lands first) — don't steal
            // the tab selection back to the stale click.
            guard ticket == openTicket else { return }
            layout.activePane?.open(document)
        }
    }

    /// Orders overlapping `openDocument` requests so a slow load can't finish
    /// last and override a newer click's selection.
    @ObservationIgnored private var openTicket = 0

    // MARK: - Opening .ibis.json

    /// Whether `url` is this project's own `.ibis.json` (the file the Project
    /// Settings editor manages), so opening it can offer that editor instead.
    private func isProjectConfigFile(_ url: URL) -> Bool {
        cacheKey(url) == cacheKey(projectConfig.fileURL)
    }

    /// Guards against showing two "how to open .ibis.json" prompts for a single
    /// click — the outline fires both a click action and a selection change.
    @ObservationIgnored private var isPromptingConfigOpen = false

    /// Routes an open of `.ibis.json` per the effective preference: straight to
    /// the settings editor, straight to the raw file, or a prompt asking which.
    private func handleProjectConfigOpen(at url: URL) {
        switch ProjectConfigOpenStore.effective(for: projectRoot) {
        case .settings: openProjectSettings()
        case .text: openDocumentTab(at: url)
        case .ask: promptProjectConfigOpen(at: url)
        }
    }

    /// Loads the config and raises the Project Settings sheet (same as the menu).
    private func openProjectSettings() {
        projectConfig.load()
        projectSettingsRequested = true
    }

    /// Asks whether to open `.ibis.json` in the Project Settings editor or as raw
    /// text, with a checkbox to remember the answer for this project.
    private func promptProjectConfigOpen(at url: URL) {
        guard !isPromptingConfigOpen else { return }
        guard let window = window ?? NSApp.keyWindow else {
            // No window to attach a sheet to — default to the settings editor.
            openProjectSettings()
            return
        }
        isPromptingConfigOpen = true
        let alert = NSAlert()
        alert.messageText = "Open “.ibis.json” in Project Settings?"
        alert.informativeText = "This file stores this project’s Ibis actions and environment variables. You can edit it in the Project Settings panel, or open the raw JSON in the editor."
        alert.addButton(withTitle: "Project Settings")
        alert.addButton(withTitle: "Open as Text")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice for this project"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPromptingConfigOpen = false
            let remember = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn: // Project Settings
                if remember { ProjectConfigOpenStore.setPreference(.settings, for: self.projectRoot) }
                self.openProjectSettings()
            case .alertSecondButtonReturn: // Open as Text
                if remember { ProjectConfigOpenStore.setPreference(.text, for: self.projectRoot) }
                self.openDocumentTab(at: url)
            default: // Cancel
                break
            }
        }
    }

    /// Opens a new, empty, untitled document as a tab in the active pane.
    func newUntitledDocument() {
        let document = OpenDocument()
        layout.activePane?.open(document)
    }

    /// Whether the integrated terminal currently holds keyboard focus (its live
    /// terminal view, or a descendant, is the window's first responder).
    var isTerminalFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return terminal.sessions.contains { session in
            guard let view = session.terminalView else { return false }
            return responder === view || responder.isDescendant(of: view)
        }
    }

    /// Opens a new tab in whichever area has focus: a terminal tab when the
    /// terminal is focused, otherwise a new editor tab. Backs ⌘T.
    func newTabInFocusedArea() {
        if isTerminalFocused {
            newTerminalTab()
        } else {
            newUntitledDocument()
        }
    }

    func saveActiveDocument() async {
        guard let document = activeDocument else { return }
        if document.isUntitled {
            await saveAs(document) // presents its own error on failure
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
    func saveAs(_ document: OpenDocument) async -> Bool {
        // The in-memory text of a read-only (non-UTF-8) or binary document does
        // not faithfully represent the file — it's a lossy U+FFFD decode, or empty
        // for a binary. Writing it out would corrupt/blank the destination, and
        // the panel defaults to the original file's own name and folder, so refuse
        // rather than offer a one-click way to overwrite the source with garbage.
        guard document.isEditable else {
            presentError("“\(document.name)” can’t be saved because it isn’t editable text (it’s read-only or binary). Copy it in Finder instead.")
            return false
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.name
        panel.directoryURL = document.url?.deletingLastPathComponent()
            ?? (isDirectory ? rootURL : rootURL.deletingLastPathComponent())
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        // Write off the main actor — a large buffer to a slow/network volume
        // would otherwise beachball the UI. Capture the edit generation so a
        // keystroke landing during the write isn't silently marked clean below.
        let contents = document.text
        let generation = document.editGeneration
        let writeURL = url.resolvingSymlinksInPath()
        let writeError: String? = await Task.detached(priority: .userInitiated) {
            do {
                try contents.write(to: writeURL, atomically: true, encoding: .utf8)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let writeError {
            presentError("Couldn’t save “\(url.lastPathComponent)”: \(writeError)")
            return false
        }
        // If a *different* document already backed this URL, retire it: point its
        // open tabs at this now-authoritative document so one file isn't split
        // across two divergent buffers (whichever saved last would clobber the
        // other). Its stale cache key is dropped by rekeyDocumentCache below.
        if let displaced = documentCache[cacheKey(url)], displaced !== document {
            for pane in layout.panes { pane.replace(displaced, with: document) }
        }
        // Adopt the file and record its on-disk metadata so our own write isn't
        // later flagged as an external change.
        document.adoptSavedFile(at: url)
        // Edits that arrived while the write was in flight aren't on disk —
        // keep them marked unsaved rather than letting adoption clear them.
        if document.editGeneration != generation { document.isDirty = true }
        documentCache[cacheKey(url)] = document
        // Drop any stale key the document was previously cached under, so its old
        // URL doesn't keep returning this now-retargeted document.
        rekeyDocumentCache()
        // Keep the pane's selection on this same document (its id is unchanged).
        Task { await reloadDirectory(at: url.deletingLastPathComponent()) }
        return true
    }

    func saveActiveDocumentAs() {
        guard let document = activeDocument else { return }
        Task { await saveAs(document) }
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
                    Task {
                        if await self.saveAs(document) {
                            self.closeTab(document, in: pane)
                            completion(true)
                        } else {
                            completion(false)
                        }
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
        evictIfUnreferenced(document)
    }

    /// Drops a cleanly-closed document from the cache once no pane shows it.
    /// Without eviction the cache grows for the window's lifetime — every closed
    /// file's text storage and undo stack stay alive, and each FSEvents batch
    /// stats (and re-reads when changed) files that aren't open anywhere. Dirty
    /// documents are kept: the guarded close path either saves first or discards
    /// explicitly via `discardDocument`.
    private func evictIfUnreferenced(_ document: OpenDocument) {
        guard !document.isDirty,
              let url = document.url,
              !layout.panes.contains(where: { pane in pane.tabDocuments.contains { $0.id == document.id } })
        else { return }
        documentCache.removeValue(forKey: cacheKey(url))
    }

    private func isOpenElsewhere(_ document: OpenDocument, excluding pane: EditorPane) -> Bool {
        layout.panes.contains { $0.id != pane.id && $0.tabDocuments.contains { $0.id == document.id } }
    }

    /// Drops a document's buffer so its unsaved edits are truly discarded; a
    /// later reopen reads fresh from disk. Untitled buffers just vanish.
    private func discardDocument(_ document: OpenDocument) {
        if let url = document.url {
            documentCache.removeValue(forKey: cacheKey(url))
        }
    }

    // MARK: - Keeping open documents in sync with the filesystem

    /// After a file/folder is renamed or moved on disk, re-point any open
    /// documents at their new location (directories move their descendants too)
    /// and re-key the cache. Without this, a later ⌘S would recreate the file at
    /// its old path and the edits would be lost. Copies (not moves) are ignored.
    func relocateOpenDocuments(from oldURL: URL, to newURL: URL) {
        // Compare canonical paths so a document opened under a different spelling
        // of the same location (symlinked root, agent-supplied realpath) still
        // gets re-pointed. `oldURL` no longer exists on disk, but its surviving
        // parent directories still resolve.
        let oldPath = cacheKey(oldURL).path
        let newPath = cacheKey(newURL).path
        var changed = false
        for document in documentCache.values {
            guard let docPath = document.url.map({ cacheKey($0).path }) else { continue }
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
            if let url = document.url { rebuilt[cacheKey(url)] = document }
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
                Task { await document.revertToSaved(force: true) }
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

    // MARK: - Agent MCP config

    /// Writes (merges) the Ibis MCP server entry into this project's agent config
    /// file, in the format of the app's chosen agent, so the agent can reach
    /// this window. Returns the human-readable result; throws if an existing
    /// config couldn't be parsed/merged. Uses the running port when the server
    /// is up, else the preferred port (same as launch-time binding).
    @discardableResult
    func addIbisToAgentConfig(settings: AppSettings) throws -> String {
        let port = MCPService.runningPort ?? settings.mcpPort
        let result = try MCPConfigWriter.write(
            agent: settings.agentKind,
            projectRoot: projectRoot,
            port: port,
            token: MCPBridge.shared.token(for: self)
        )
        return result.message
    }

    /// Drives the proactive "add Ibis to your MCP config?" prompt in the window.
    var mcpAdoptionOffer = false

    /// Drives the "modernize the hardcoded Ibis MCP entry?" prompt in the window.
    var mcpUpgradeOffer = false

    /// Decides whether to proactively offer to add Ibis to this project's
    /// existing agent MCP config — or, when an Ibis entry exists but is the
    /// legacy *hardcoded* form (inline token/port), to modernize it. Fires only
    /// when the agent feature is on and the user hasn't declined that offer
    /// before. Skipped while a trust decision is pending so two prompts don't
    /// stack on the same window. (The two offers can't co-fire: a legacy entry
    /// means Ibis is present, which suppresses the adoption offer.)
    func evaluateAgentConfigOffer(settings: AppSettings) {
        guard MCPService.isAvailable, settings.mcpEnabled else { return }
        guard !trustPromptNeeded else { return }
        // A hardcoded entry leaks the writer's token if committed, and resolves
        // only on the machine (and, with the default ephemeral port, only the
        // app launch) that wrote it — a teammate's hand-run agent silently gets
        // no Ibis tools. Offer to rewrite it to the portable env-var form.
        if MCPConfigWriter.claudeConfigNeedsPortabilityUpgrade(projectRoot: projectRoot),
           !MCPAdoptionStore.hasDeclinedUpgrade(projectRoot) {
            mcpUpgradeOffer = true
            return
        }
        guard !MCPAdoptionStore.hasDeclined(projectRoot) else { return }
        guard MCPConfigWriter.projectState(agent: settings.agentKind, projectRoot: projectRoot) == .missingIbis else { return }
        mcpAdoptionOffer = true
    }

    /// Rewrites the legacy hardcoded Ibis entry in `.mcp.json` to the portable
    /// env-var form (undoing the old 0600/gitignore hardening, which no longer
    /// applies to a secret-free file). Returns the human-readable result.
    @discardableResult
    func upgradeAgentConfigPortability(settings: AppSettings) throws -> String {
        let port = MCPService.runningPort ?? settings.mcpPort
        return try MCPConfigWriter.upgradeClaudeConfigPortability(
            projectRoot: projectRoot,
            port: port,
            token: MCPBridge.shared.token(for: self)
        ).message
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
    /// Throws when the write fails (read-only folder, full volume) so the sheet
    /// can surface it — a swallowed failure looked committed, worked in memory
    /// for the session, and silently vanished on relaunch.
    func commitProjectSettings() throws {
        try projectConfig.save()
        if isTrusted {
            applyProjectEnv()
        } else if projectConfig.hasExecutableContent {
            // Re-raise the trust prompt whenever an untrusted folder's config
            // carries executable content — including a folder the user earlier
            // declined. Otherwise "Don't Trust" (or a reflexive Esc on the alert)
            // is a permanent dead-end with no UI to ever enable env/actions.
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
    @discardableResult
    func runAgent(command: String, name: String) -> TerminalSession {
        let session = terminal.newSession(command: command, title: name, role: .agent)
        terminal.isVisible = true
        return session
    }

    /// The agent terminal to receive a "Send to Agent" payload: the active tab if
    /// it's a running agent, otherwise the most recently opened running agent tab.
    /// nil when no agent is running (the caller then launches one).
    var runningAgentSession: TerminalSession? {
        if let active = terminal.activeSession, active.role == .agent, active.isRunning {
            return active
        }
        return terminal.sessions.last { $0.role == .agent && $0.isRunning }
    }

    /// Delivers `text` to the agent's prompt without submitting it, so the user
    /// can add context before pressing Return. Reveals the dock and focuses the
    /// agent tab. If no agent is running, launches the configured agent and
    /// queues the text to arrive once its prompt is ready.
    func sendToAgent(_ text: String) {
        guard !text.isEmpty else { return }
        // A trailing space keeps successive sends from gluing together.
        let payload = text.hasSuffix(" ") ? text : text + " "
        terminal.isVisible = true

        if let agent = runningAgentSession {
            terminal.activeSessionID = agent.id
            agent.insertAtPrompt(payload)
            return
        }

        guard let settings else { return }
        launchConfiguredAgent(settings: settings)
        // The freshly launched agent is now the active tab; it delivers the
        // queued text once its view is built and the process is up.
        if let launched = terminal.activeSession, launched.role == .agent {
            launched.pendingPromptText = payload
        }
    }

    /// A file/folder reference for the agent: its path relative to the workspace
    /// root (the root itself becomes "."), double-quoted when it contains spaces
    /// or quotes — an embedded `"` is backslash-escaped so the quoted token stays
    /// well-formed rather than splitting into garbage at the agent prompt.
    func agentPathReference(for url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        let relative: String
        if full == root {
            relative = "."
        } else if full.hasPrefix(root + "/") {
            relative = String(full.dropFirst(root.count + 1))
        } else {
            relative = full
        }
        guard relative.contains(" ") || relative.contains("\"") else { return relative }
        return "\"\(relative.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// The window's agent tab, whatever state its process is in. One project
    /// has one agent tab (and, for Claude, one deterministic session), so every
    /// launch route targets this before creating anything.
    var agentTab: TerminalSession? {
        terminal.sessions.first { $0.role == .agent }
    }

    /// Opens the project's agent: the single entry point for every
    /// user-initiated launch (toolbar, menu bar, intents, CLI), and idempotent —
    /// "Open Claude" always lands on THE agent for this project. If the agent
    /// tab already exists it is focused (restarted first if its process exited);
    /// otherwise one is created. For Claude the tab launches into the project's
    /// deterministic session (`MCPService.projectSessionID`), resuming its
    /// conversation when a transcript exists and creating it when not — fully
    /// derived from the project path, nothing persisted.
    func launchConfiguredAgent(settings: AppSettings) {
        if let tab = agentTab {
            terminal.isVisible = true
            terminal.activeSessionID = tab.id
            tab.wantsFocus = true
            if tab.hasStarted, !tab.isRunning {
                let override = settings.terminalShellPath.isEmpty ? nil : settings.terminalShellPath
                restartTerminalSession(tab, settings: settings, shellOverride: override)
            }
            return
        }

        if settings.agentKind == .claude {
            guard let (command, resume) = MCPService.agentRelaunchCommand(
                settings: settings,
                sessionID: MCPService.projectSessionID(for: projectRoot),
                workingDirectory: projectRoot,
                mcpConfig: MCPService.claudeMCPConfig(for: self, settings: settings)
            ) else { return }
            MCPService.bindAgent(to: self, settings: settings)
            let launched = runAgent(command: command, name: settings.agentName)
            if resume { armResumeRecovery(for: launched, settings: settings) }
            return
        }

        guard let command = MCPService.launchCommand(
            settings: settings,
            mcpConfig: MCPService.claudeMCPConfig(for: self, settings: settings)
        ) else { return }
        MCPService.bindAgent(to: self, settings: settings)
        runAgent(command: command, name: settings.agentName)
    }

    /// Restarts an exited terminal tab in its own view. A Claude agent tab
    /// can't just re-run its original command (see
    /// `MCPService.agentRelaunchCommand` for the resume-vs-re-pin rule), and an
    /// agent tab is re-bound first so a changed MCP port since the original
    /// launch doesn't leave the relaunched agent reading a stale project config.
    func restartTerminalSession(_ session: TerminalSession, settings: AppSettings, shellOverride: String?) {
        if session.role == .agent {
            MCPService.bindAgent(to: self, settings: settings)
            if settings.agentKind == .claude,
               let (command, _) = MCPService.agentRelaunchCommand(
                   settings: settings,
                   sessionID: MCPService.projectSessionID(for: projectRoot),
                   workingDirectory: projectRoot,
                   mcpConfig: MCPService.claudeMCPConfig(for: self, settings: settings)
               ) {
                session.restart(shellOverride: shellOverride, command: command)
                return
            }
        }
        session.restart(shellOverride: shellOverride)
    }

    /// Shows a desktop notification that a terminal program explicitly requested
    /// (OSC 9/777) — but only when the human isn't already looking at that
    /// session; if they are, there's nothing to call them back to (WezTerm's
    /// "suppress from focused window", refined to the tab). The program decided
    /// it was worth interrupting for, so this honors it for any session, using
    /// the program's own message. A tap raises this window.
    ///
    /// The title is always "<sender> in <project>", not the program's own title:
    /// agents send a static one ("Claude Code") that reads identically from
    /// every window, and the whole point of the ping is knowing *which* project
    /// wants the human back.
    private func handleTerminalNotification(_ session: TerminalSession, title: String?, body: String) {
        guard !isSessionOnScreen(session) else { return }
        let notificationTitle = session.role == .agent
            ? agentNotificationTitle
            : "\(title ?? session.title) in \(displayName)"
        DesktopNotifier.shared.post(
            title: notificationTitle,
            body: body.isEmpty ? "Needs your attention" : body,
            token: MCPBridge.shared.token(for: self)
        )
    }

    /// A bell from a session that isn't on screen also becomes a desktop
    /// notification — the fallback attention signal for programs that never
    /// emit a notification OSC. The session debounces bells and swallows the
    /// ones that ride along with an explicit OSC notification.
    private func handleTerminalBell(_ session: TerminalSession) {
        guard !isSessionOnScreen(session) else { return }
        let agent = session.role == .agent
        DesktopNotifier.shared.post(
            title: agent ? agentNotificationTitle : "Terminal in \(displayName)",
            body: agent ? "Needs your attention" : "\(session.title) rang the terminal bell",
            token: MCPBridge.shared.token(for: self)
        )
    }

    /// Whether the human is plausibly looking at this session right now: its
    /// window is key (which also implies Ibis is the active app), the dock is
    /// showing, and the session is the dock's active tab. An agent finishing in
    /// a background tab of the focused window still warrants a ping — the user
    /// can't see it.
    private func isSessionOnScreen(_ session: TerminalSession) -> Bool {
        guard let window, window === NSApp.keyWindow else { return false }
        return terminal.isVisible && terminal.activeSessionID == session.id
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
        // Flush the layout now: persistence is otherwise edge-triggered, so a
        // change made before the restore gate opened would be lost with the
        // window.
        persistLayoutState()
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
        persistLayoutState()
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
                if !(await saveAs(document)) { allSucceeded = false }
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
