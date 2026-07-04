import SwiftUI
import AppKit

enum SidebarMode: Hashable {
    case files
    case search
}

/// The main editing surface for an opened workspace: the sidebar (file browser
/// or project search) alongside the tabbed, splittable editor area.
struct WorkspaceView: View {
    let ref: WorkspaceRef

    @Environment(AppSettings.self) private var settings

    @State private var workspace: Workspace?
    @State private var selection: FileNode.ID?
    @State private var sidebarMode: SidebarMode = .files
    @State private var searchModel = ProjectSearchModel()
    @State private var goToLineText = ""
    @State private var selectedActionName: String?

    @State private var bridge = MCPBridge.shared
    @State private var router = LaunchRouter.shared

    var body: some View {
        VStack(spacing: 0) {
            splitView
            if let workspace {
                Divider()
                StatusBarView(git: workspace.git)
            }
        }
        // Transient banner posted by the MCP `notify` tool.
        .overlay(alignment: .top) {
            if let banner = bridge.banner, let workspace,
               bridge.bannerToken == bridge.token(for: workspace) {
                MCPBannerView(text: banner)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner) {
                        try? await Task.sleep(for: .seconds(4))
                        bridge.banner = nil
                        bridge.bannerToken = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: bridge.banner)
        // Project Settings editor (.ibis.json).
        .sheet(isPresented: projectSettingsPresented) {
            if let workspace {
                ProjectSettingsView(
                    config: workspace.projectConfig,
                    commit: { workspace.commitProjectSettings() },
                    dismiss: { workspace.projectSettingsRequested = false }
                )
            }
        }
        // Folder-trust prompt: shown once when a folder ships executable
        // .ibis.json content. Until trusted, its environment and actions are
        // withheld, so opening it can't run code.
        .alert("Do you trust this folder?", isPresented: trustPromptPresented) {
            Button("Trust Folder") {
                workspace?.resolveTrust(true)
                if let workspace, workspace.pendingAgentLaunch {
                    workspace.pendingAgentLaunch = false
                    launchAgent(in: workspace)
                }
            }
            Button("Don’t Trust", role: .cancel) {
                workspace?.resolveTrust(false)
                workspace?.pendingAgentLaunch = false
            }
        } message: {
            Text(trustPromptMessage)
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 520)
                .navigationTitle(workspace?.displayName ?? "Ibis")
        } detail: {
            detail
        }
        // NOTE: a customizable `.toolbar(id:)` crashes here — inside a
        // NavigationSplitView, SwiftUI inserts its automatic sidebar-toggle item
        // twice ("already contains an item with identifier …toggleSidebar").
        // So this stays a plain, non-customizable ToolbarItemGroup.
        .toolbar {
            // Project action runner — shown only when actions are configured.
            // (The condition lives at the toolbar-content level, not inside a
            // ToolbarItemGroup, where SwiftUI handles `if` unreliably.)
            if let workspace, !workspace.availableActions.isEmpty {
                ToolbarItemGroup(placement: .navigation) {
                    Picker("Action", selection: $selectedActionName) {
                        ForEach(workspace.availableActions) { action in
                            Text(action.name).tag(Optional(action.name))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 90)
                    // Can't switch actions while one is running.
                    .disabled(workspace.terminal.isActionRunning)

                    // One button with conditional content (not a structural
                    // if/else, which SwiftUI handles unreliably in a toolbar
                    // group): Run when idle, Stop while an action is running.
                    Button {
                        if workspace.terminal.isActionRunning {
                            workspace.stopProjectAction()
                        } else {
                            runSelectedAction()
                        }
                    } label: {
                        Label(
                            workspace.terminal.isActionRunning ? "Stop Action" : "Run Action",
                            systemImage: workspace.terminal.isActionRunning ? "stop.fill" : "play.fill"
                        )
                    }
                    .tint(workspace.terminal.isActionRunning ? .red : nil)
                    // Surface the exact command that will run, so a project-supplied
                    // "Build" action can't hide something like `curl … | sh`.
                    .help(workspace.terminal.isActionRunning
                          ? "Stop the running action"
                          : "Run: \(selectedActionCommand(workspace))")
                }
            }

            // Project Settings — always available (to add actions / env).
            ToolbarItem(placement: .navigation) {
                Button {
                    workspace?.projectConfig.load()
                    workspace?.projectSettingsRequested = true
                } label: {
                    Label("Project Settings", systemImage: "slider.horizontal.3")
                }
                .disabled(workspace == nil)
                .help("Project Settings (actions & environment)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    sidebarMode = .search
                } label: {
                    Label("Search in Folder", systemImage: "magnifyingglass")
                }
                .disabled(workspace == nil)
                .help("Search in Folder (⇧⌘F)")

                Button {
                    workspace?.layout.splitActive()
                } label: {
                    Label("Split Editor", systemImage: "rectangle.split.2x1")
                }
                .disabled(activeDocument == nil)
                .help("Split Editor (⌘\\)")

                Button {
                    if let workspace { Task { await workspace.saveActiveDocument() } }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(activeDocument?.isDirty != true)
                .help("Save (⌘S)")

                Button {
                    workspace?.toggleTerminal()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .disabled(workspace == nil)
                .help("Show or Hide Terminal (⌃`)")

                Button(action: openAgent) {
                    Label("Open in \(settings.agentName)", systemImage: "sparkles")
                }
                .disabled(workspace == nil || settings.agentCommandLine == nil)
                .help("Run \(settings.agentName) in a terminal (⌃⇧A)")
            }
        }
        // ⌘W closes the active tab (a key-window control, so it takes precedence
        // over the built-in window Close). Disabled when no tab is open, so ⌘W
        // then falls through to closing the window.
        .background { hiddenKeyboardShortcuts }
        // Confirm unsaved changes before the window closes (as a sheet).
        .background {
            WindowCloseGuard { proceed in workspace?.requestWindowClose(proceed: proceed) ?? true }
        }
        // Give the workspace its window (for sheet-attached confirmations) and
        // mirror the active document's dirty state into the close-button dot.
        // Re-evaluates whenever the observed dirty flag / active tab changes.
        .background {
            WindowBridge(workspace: workspace, edited: activeDocument?.isDirty ?? false)
        }
        // Expose the frontmost window's workspace and sidebar mode to the menu
        // bar. Scene-scoped (not focus-scoped) so commands like Show Terminal
        // work whenever the window is active, even with no editor focused.
        .focusedSceneValue(\.activeWorkspace, workspace)
        .focusedSceneValue(\.sidebarMode, $sidebarMode)
        // Persist tabs/panes/selection whenever the layout changes.
        .onChange(of: workspace?.layoutFingerprint) { _, _ in
            workspace?.persistLayoutState()
        }
        // Default the action picker to the first action, keeping it valid as the
        // configured actions change.
        .onChange(of: workspace?.availableActions.map(\.name) ?? [], initial: true) { _, names in
            if selectedActionName == nil || !(names.contains { $0 == selectedActionName }) {
                selectedActionName = names.first
            }
        }
        // Go to Line prompt (⌘L), driven by the workspace's request flag.
        .alert("Go to Line", isPresented: goToLinePresented) {
            TextField("Line number", text: $goToLineText)
            Button("Go") {
                if let line = Int(goToLineText.trimmingCharacters(in: .whitespaces)) {
                    workspace?.goToLine(line)
                }
                goToLineText = ""
            }
            Button("Cancel", role: .cancel) { goToLineText = "" }
        }
        // Start/stop the MCP server to match settings (idempotent), and let
        // agent tools address this window.
        .task { MCPService.apply(settings: settings) }
        .onDisappear {
            if let workspace {
                workspace.resolvePendingDiff(apply: false)
                MCPBridge.shared.unregister(workspace)
            }
        }
        // Agent-proposed edit review (MCP propose_edit); dismiss = discard.
        .sheet(isPresented: diffReviewPresented) {
            if let proposal = workspace?.pendingDiff {
                DiffReviewView(
                    proposal: proposal,
                    onApply: { workspace?.resolvePendingDiff(apply: true) },
                    onDiscard: { workspace?.resolvePendingDiff(apply: false) }
                )
            }
        }
        .task(id: ref) {
            let workspace = Workspace(rootURL: ref.url, isDirectory: ref.isDirectory)
            self.workspace = workspace
            MCPBridge.shared.register(workspace)
            await workspace.rootNode.loadChildren()
            workspace.refreshRootEmptiness()
            if ref.isDirectory {
                // Reopen the tabs/panes/selection from the last session.
                await workspace.restorePersistedLayout()
            } else {
                selection = workspace.rootNode.id
            }
            // Honor an "Open in Agent" request (one-shot; restored windows never
            // re-launch the agent because they aren't in the pending set).
            if LaunchRouter.shared.consumeAgentLaunch(for: workspace.rootURL) {
                armAgentLaunch(in: workspace)
            }
        }
        .task(id: selection) {
            guard let selection, let workspace else { return }
            let document = workspace.document(for: selection)
            await document.loadIfNeeded()
            workspace.layout.activePane?.open(document)
        }
        // An "Open in Agent" request for a folder whose window is *already* open
        // is delivered here (the new-window `.task` above wouldn't re-run). This
        // both honors that request and stops the flag from lingering to fire on a
        // later, unrelated open of the folder.
        .onChange(of: router.agentLaunchSignal) {
            guard let workspace, router.consumeAgentLaunch(for: workspace.rootURL) else { return }
            armAgentLaunch(in: workspace)
        }
    }

    /// Launches the configured agent for an "Open in Agent" request, but only
    /// into a *trusted* folder. An agent runs the folder's own auto-executing
    /// config (hooks, MCP servers) on startup, so an untrusted folder — which a
    /// Shortcut/Siri call could point at an attacker-staged directory — must be
    /// trusted first. Defers the launch behind the trust prompt otherwise.
    private var trustPromptMessage: String {
        let name = workspace?.displayName ?? "This folder"
        if workspace?.pendingAgentLaunch == true {
            return "You asked to open “\(name)” in an agent. The agent can run this folder’s own configuration (hooks, MCP servers, tasks) as soon as it starts. Trust it only if you created it or it came from a source you trust."
        }
        return "“\(name)” contains an .ibis.json with environment variables or actions. Ibis applies them to terminals and runs its actions only if you trust it. Don’t trust folders you didn’t create or that came from an untrusted source."
    }

    private func armAgentLaunch(in workspace: Workspace) {
        if workspace.isTrusted {
            launchAgent(in: workspace)
        } else {
            workspace.pendingAgentLaunch = true
            workspace.trustPromptNeeded = true
        }
    }

    /// Hidden key-window controls: these take precedence over menu equivalents
    /// (⌘W closes the active tab rather than the window; ⌘= zooms in — the menu
    /// shows ⌘+, which on ANSI layouts is ⇧⌘=, but people press the unshifted =).
    @ViewBuilder
    private var hiddenKeyboardShortcuts: some View {
        Group {
            Button("Close Tab") { workspace?.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(activeDocument == nil)

            Button("Increase Font Size") {
                settings.fontSize = min(settings.fontSize + 1, 48)
            }
            .keyboardShortcut("=", modifiers: .command)
        }
        .hidden()
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if let workspace {
            VStack(spacing: 0) {
                Picker("Sidebar Mode", selection: $sidebarMode) {
                    Label("Files", systemImage: "folder").tag(SidebarMode.files)
                    Label("Search", systemImage: "magnifyingglass").tag(SidebarMode.search)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .padding(.horizontal, 8)
                .frame(height: EditorChrome.headerHeight)

                Divider()

                switch sidebarMode {
                case .files:
                    FileOutlineView(workspace: workspace, selection: $selection)
                        .overlay {
                            if workspace.rootIsEmpty {
                                ContentUnavailableView {
                                    Label("Empty Folder", systemImage: "folder")
                                } description: {
                                    Text("Create a file with ⌘N, or drop files here.")
                                }
                                // Let Finder drops still reach the outline below.
                                .allowsHitTesting(false)
                            }
                        }
                case .search:
                    ProjectSearchView(
                        model: searchModel,
                        root: workspace.rootURL,
                        onOpen: openSearchResult
                    )
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Detail

    private var activeDocument: OpenDocument? {
        workspace?.layout.activePane?.selectedDocument
    }

    private var goToLinePresented: Binding<Bool> {
        Binding(
            get: { workspace?.goToLineRequested ?? false },
            set: { workspace?.goToLineRequested = $0 }
        )
    }

    private var trustPromptPresented: Binding<Bool> {
        Binding(
            get: { workspace?.trustPromptNeeded ?? false },
            set: { if !$0 { workspace?.trustPromptNeeded = false } }
        )
    }

    private var diffReviewPresented: Binding<Bool> {
        Binding(
            get: { workspace?.pendingDiff != nil },
            set: { presented in
                // Dismissed without a button (Esc / click-away) → discard.
                if !presented { workspace?.resolvePendingDiff(apply: false) }
            }
        )
    }

    /// The persisted terminal dock size, as `CGFloat` bindings for the resize
    /// handle. Written back to settings so they survive relaunch.
    private var terminalHeightBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(settings.terminalDockHeight) },
            set: { settings.terminalDockHeight = Double($0) }
        )
    }

    private var terminalWidthBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(settings.terminalDockWidth) },
            set: { settings.terminalDockWidth = Double($0) }
        )
    }

    /// Launches the configured agent in a new terminal, revealing the dock.
    private func openAgent() {
        guard let workspace else { return }
        launchAgent(in: workspace)
    }

    private func launchAgent(in workspace: Workspace) {
        guard let command = MCPService.launchCommand(settings: settings) else { return }
        MCPService.bindAgent(to: workspace, settings: settings)
        workspace.runAgent(command: command, name: settings.agentName)
    }

    /// Runs the toolbar-selected action (falling back to the first) in the Run tab.
    private func runSelectedAction() {
        guard let workspace else { return }
        if let action = selectedAction(workspace) { workspace.runProjectAction(action) }
    }

    /// The action currently chosen in the toolbar picker (falling back to first).
    private func selectedAction(_ workspace: Workspace) -> ProjectConfig.Action? {
        let actions = workspace.availableActions
        return actions.first { $0.name == selectedActionName } ?? actions.first
    }

    /// The command line of the selected action, for the Run button's tooltip.
    private func selectedActionCommand(_ workspace: Workspace) -> String {
        selectedAction(workspace)?.command ?? ""
    }

    private var projectSettingsPresented: Binding<Bool> {
        Binding(
            get: { workspace?.projectSettingsRequested ?? false },
            set: { workspace?.projectSettingsRequested = $0 }
        )
    }

    private var editorConfiguration: EditorConfiguration {
        EditorConfiguration(
            fontName: settings.fontName,
            fontSize: settings.fontSize,
            tabWidth: settings.tabWidth,
            usesSoftTabs: settings.usesSoftTabs,
            wordWrap: settings.wordWrap,
            showLineNumbers: settings.showLineNumbers,
            showInvisibles: settings.showInvisibles,
            lightTheme: settings.lightTheme,
            darkTheme: settings.darkTheme
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let workspace {
            GeometryReader { proxy in
                let trailing = settings.terminalPlacement == .trailing
                let isVisible = workspace.terminal.isVisible
                // AnyLayout swaps V/H arrangement without changing subview
                // identity, so the SwiftTerm views survive an orientation flip.
                let layout = trailing
                    ? AnyLayout(HStackLayout(spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))

                // Clamp so neither the editor nor the terminal can vanish.
                let maxHeight = max(120, proxy.size.height - 140)
                let maxWidth = max(200, proxy.size.width - 280)
                let height = min(max(80, CGFloat(settings.terminalDockHeight)), maxHeight)
                let width = min(max(200, CGFloat(settings.terminalDockWidth)), maxWidth)

                layout {
                    editorArea(workspace)

                    if isVisible {
                        if trailing {
                            TerminalResizeHandle(size: terminalWidthBinding, minSize: 200, maxSize: maxWidth, vertical: true)
                        } else {
                            TerminalResizeHandle(size: terminalHeightBinding, minSize: 80, maxSize: maxHeight, vertical: false)
                        }
                    }

                    dock(workspace)
                        .frame(width: trailing ? width : nil, height: trailing ? nil : height)
                        .frame(
                            width: trailing ? (isVisible ? width : 0) : nil,
                            height: trailing ? nil : (isVisible ? height : 0)
                        )
                        .clipped()
                        .allowsHitTesting(isVisible)
                }
            }
            .navigationTitle(activeDocument?.name ?? workspace.displayName)
            .navigationSubtitle(workspace.displayName)
            // Title-bar proxy icon (⌘-click path menu, draggable to Finder).
            .navigationDocument(activeDocument?.url ?? workspace.rootURL)
        } else {
            ContentUnavailableView(
                "No File Open",
                systemImage: "doc.text",
                description: Text("Select a file from the sidebar to start editing.")
            )
        }
    }

    private func editorArea(_ workspace: Workspace) -> some View {
        EditorAreaView(
            workspace: workspace,
            layout: workspace.layout,
            configuration: editorConfiguration,
            onCloseTab: { document, pane in workspace.requestCloseTab(document, in: pane) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The dock stays mounted at its real size even when hidden (an outer frame
    // collapses the space, the inner frame keeps the terminal sized) so
    // SwiftTerm views are never detached — detaching resets their scrollback.
    private func dock(_ workspace: Workspace) -> some View {
        TerminalDockView(dock: workspace.terminal)
    }

    private func openSearchResult(_ url: URL, _ range: NSRange) {
        guard let workspace else { return }
        Task {
            let document = workspace.document(for: url)
            await document.loadIfNeeded()
            document.pendingSelection = range
            workspace.layout.activePane?.open(document)
        }
    }
}

/// A small floating banner used by the MCP `notify` tool.
private struct MCPBannerView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.ibisKelly)
            Text(text)
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
        .accessibilityLabel("Agent notification: \(text)")
    }
}

/// Bridges the hosting `NSWindow` to the workspace: hands the window to the
/// model (so unsaved-changes confirmations can attach as sheets) and mirrors the
/// active document's dirty state into `isDocumentEdited` (the close-button dot).
private struct WindowBridge: NSViewRepresentable {
    var workspace: Workspace?
    var edited: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let workspace = workspace
        let edited = edited
        DispatchQueue.main.async {
            let window = nsView.window
            workspace?.window = window
            window?.isDocumentEdited = edited
        }
    }
}

/// A draggable divider between the editor and the terminal dock. Dragging
/// toward the editor grows the terminal; the size is clamped so both stay
/// usable. `vertical` means a vertical divider (terminal on the trailing edge).
private struct TerminalResizeHandle: View {
    @Binding var size: CGFloat
    let minSize: CGFloat
    let maxSize: CGFloat
    let vertical: Bool

    @State private var dragStart: CGFloat?

    var body: some View {
        let line = Rectangle().fill(Color(nsColor: .separatorColor))
        Group {
            if vertical { line.frame(width: 1) } else { line.frame(height: 1) }
        }
        .frame(width: vertical ? 6 : nil, height: vertical ? nil : 6)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .contentShape(Rectangle())
        // `pointerStyle` sets the resize cursor only while the pointer is over
        // the handle and restores it automatically — unlike a manual
        // NSCursor.push()/pop() in onHover, which leaks a pushed cursor if the
        // handle is unmounted (⌃` hiding the terminal) while hovered.
        .pointerStyle(vertical ? .columnResize : .rowResize)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let base = dragStart ?? size
                    if dragStart == nil { dragStart = base }
                    let delta = vertical ? value.translation.width : value.translation.height
                    size = min(max(minSize, base - delta), maxSize)
                }
                .onEnded { _ in dragStart = nil }
        )
        // Expose the drag-only divider to assistive tech.
        .accessibilityElement()
        .accessibilityLabel("Resize Terminal")
        .accessibilityValue(vertical ? "Width \(Int(size))" : "Height \(Int(size))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 24
            switch direction {
            case .increment: size = min(size + step, maxSize)
            case .decrement: size = max(size - step, minSize)
            @unknown default: break
            }
        }
    }
}
