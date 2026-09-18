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

    /// The terminal's size (width when trailing, height when bottom) captured at
    /// the start of a divider drag, so the drag applies its cumulative
    /// translation against a stable base rather than compounding.
    @State private var terminalDragBase: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            splitView
            if let workspace {
                Divider()
                StatusBarView(git: workspace.git)
            }
        }
        // Everything in this window — including its sheets, which inherit the
        // environment — tints with the project's accent when it sets one.
        // `.tint(nil)` (the no-override case) leaves the system accent alone;
        // the environment value is what Ibis's own explicitly-accented chrome
        // reads, since `Color.accentColor` doesn't follow `.tint`.
        .environment(\.ibisAccent, appearance.accentColor)
        .tint(appearance.accent == nil ? nil : appearance.accentColor)
        // Transient banner posted by the MCP `notify` tool.
        .overlay(alignment: .top) {
            if let banner = bridge.banner, let workspace,
               bridge.bannerToken == bridge.token(for: workspace) {
                MCPBannerView(text: banner)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // Keyed on the epoch (not the text) so a repost of the same
                    // message restarts the timer. The cancellation guard matters:
                    // when a new banner replaces this one, `Task.sleep` throws,
                    // `try?` swallows it, and falling through would wipe the
                    // *new* banner a frame after it appeared.
                    .task(id: bridge.bannerEpoch) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
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
                    workspace: workspace,
                    commit: { try workspace.commitProjectSettings() },
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
        // Proactive offer to wire Ibis into a project that already has an agent
        // MCP config but doesn't yet reference Ibis (only when the MCP server is
        // enabled). Declining is remembered so it doesn't re-ask every open.
        .alert("Add Ibis to this project’s agent?", isPresented: mcpOfferPresented) {
            Button("Add Ibis Tools") {
                guard let workspace else { return }
                do {
                    try workspace.addIbisToAgentConfig(settings: settings)
                } catch {
                    workspace.presentError("Couldn’t add Ibis to the MCP config: \(error.localizedDescription)")
                }
            }
            Button("Not Now", role: .cancel) {
                if let workspace { MCPAdoptionStore.setDeclined(workspace.projectRoot) }
            }
        } message: {
            Text("“\(workspace?.displayName ?? "This project")” already has an MCP configuration but doesn’t include Ibis. Add it so \(settings.agentName) can use Ibis’s tools (open files, propose edits, and more) in this window.")
        }
        // Legacy hardcoded Ibis entry (inline token/port) detected on open:
        // offer to rewrite it to the portable env-var form. Declining is
        // remembered per project.
        .alert("Update this project’s Ibis MCP entry?", isPresented: mcpUpgradePresented) {
            Button("Update Entry") {
                guard let workspace else { return }
                do {
                    try workspace.upgradeAgentConfigPortability(settings: settings)
                } catch {
                    workspace.presentError("Couldn’t update the Ibis MCP entry: \(error.localizedDescription)")
                }
            }
            Button("Not Now", role: .cancel) {
                if let workspace { MCPAdoptionStore.setDeclinedUpgrade(workspace.projectRoot) }
            }
        } message: {
            Text(".mcp.json points at Ibis with a hardcoded token and port, which works only on the machine that wrote it — and exposes the token if the file is committed. Ibis can rewrite the entry to use environment variables so the same file works for every developer.")
        }
    }

    private var navigationRoot: some View {
        NavigationSplitView {
            WorkspaceSidebar(
                workspace: workspace,
                selection: $selection,
                mode: $sidebarMode,
                searchModel: searchModel,
                onOpenSearchResult: openSearchResult
            )
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 520)
                .navigationTitle(workspace?.displayName ?? "Ibis")
        } detail: {
            WorkspaceDetail(
                workspace: workspace,
                settings: settings,
                configuration: editorConfiguration,
                terminalDragBase: $terminalDragBase
            )
        }
        // NOTE: a customizable `.toolbar(id:)` crashes here — inside a
        // NavigationSplitView, SwiftUI inserts its automatic sidebar-toggle item
        // twice ("already contains an item with identifier …toggleSidebar").
        // So this stays a plain, non-customizable ToolbarItemGroup.
        // (Toolbar content lives in its own builder property — inlining it made
        // this whole expression exceed the type-checker's time limit.)
        .toolbar {
            WorkspaceToolbar(
                workspace: workspace,
                settings: settings,
                sidebarMode: $sidebarMode,
                selectedActionName: $selectedActionName,
                openAgent: openAgent
            )
        }
    }

    private var splitView: some View {
        navigationRoot
        // ⌘W closes the active tab (a key-window control, so it takes precedence
        // over the built-in window Close). Disabled when no tab is open, so ⌘W
        // then falls through to closing the window.
        .background {
            WorkspaceKeyboardShortcuts(
                workspace: workspace,
                activeDocument: activeDocument,
                settings: settings
            )
        }
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
                // Same for a blocking ask_human sheet: its completion handler
                // never fires when the window closes, so resolve it explicitly
                // or the agent's MCP request hangs forever.
                MCPBridge.shared.cancelPrompts(for: workspace)
                MCPBridge.shared.unregister(workspace)
                // Kill this window's shells/agents/actions. Nothing else does:
                // SwiftTerm's pending PTY read keeps each process object alive
                // past dealloc, so without this a closed window leaks a live
                // shell (or a still-running agent) until app quit.
                workspace.terminal.terminateAll()
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
            // The sibling `.task` above also starts the MCP server, but the two
            // tasks have no ordering guarantee. `apply` is idempotent, so kick
            // it here too and wait for the bind to settle — otherwise a cold
            // `ibis --agent` launch (or an agent-tab restore) can race the
            // transport and start the agent with no Ibis tools for its whole
            // session.
            MCPService.apply(settings: settings)
            await MCPService.awaitReady()
            let workspace = Workspace(rootURL: ref.url, isDirectory: ref.isDirectory)
            workspace.settings = settings
            self.workspace = workspace
            MCPBridge.shared.register(workspace)
            // Every terminal/agent session in this window gets the project's MCP
            // token and the server's live port: Codex reads the token via
            // bearer_token_env_var, and a hand-run `claude` resolves both
            // through the `${IBIS_MCP_TOKEN}` / `${IBIS_MCP_PORT}` references
            // in .mcp.json. The env-var indirection is what makes a *committed*
            // .mcp.json portable: the file carries nothing machine-specific, so
            // each teammate's Ibis supplies its own values (the port is
            // ephemeral by default — inlined, it broke the config on any other
            // machine, and on this one after a relaunch). Inert while MCP is off.
            if MCPService.isAvailable {
                workspace.terminal.extraLaunchEnvironment["IBIS_MCP_TOKEN"] =
                    MCPBridge.shared.token(for: workspace)
                if let port = MCPService.runningPort {
                    workspace.terminal.extraLaunchEnvironment["IBIS_MCP_PORT"] = String(port)
                }
            }
            await workspace.rootNode.loadChildren()
            workspace.refreshRootEmptiness()
            // Reopen the tabs/panes/selection and terminal dock from the last
            // session, then open the persistence gate (both inside).
            await workspace.restoreSession(settings: settings)
            if !ref.isDirectory {
                selection = workspace.rootNode.id
            }
            // Honor an "Open in Agent" request (one-shot; restored windows never
            // re-launch the agent because they aren't in the pending set).
            if LaunchRouter.shared.consumeAgentLaunch(for: workspace.rootURL) {
                armAgentLaunch(in: workspace)
            }
            // Offer to wire Ibis into a project that already uses MCP. Last, so
            // an immediate agent launch above (which writes the config itself)
            // is reflected and no offer fires.
            workspace.evaluateAgentConfigOffer(settings: settings)
        }
        .task(id: selection) {
            guard let selection, let workspace else { return }
            // Route through openDocument so overlapping opens (this task and an
            // outline click, or two quick clicks) are ordered by its ticket and
            // a slow load can't override a newer click's selection.
            workspace.openDocument(at: selection)
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

    private var mcpOfferPresented: Binding<Bool> {
        Binding(
            get: { workspace?.mcpAdoptionOffer ?? false },
            set: { if !$0 { workspace?.mcpAdoptionOffer = false } }
        )
    }

    private var mcpUpgradePresented: Binding<Bool> {
        Binding(
            get: { workspace?.mcpUpgradeOffer ?? false },
            set: { if !$0 { workspace?.mcpUpgradeOffer = false } }
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

    /// Launches the configured agent in a new terminal, revealing the dock.
    private func openAgent() {
        guard let workspace else { return }
        launchAgent(in: workspace)
    }

    private func launchAgent(in workspace: Workspace) {
        Task {
            // The MCP transport binds asynchronously (and a port change restarts
            // it after a delay); launching before it settles reads no port and
            // silently starts the agent without Ibis tools.
            await MCPService.awaitReady()
            workspace.launchConfiguredAgent(settings: settings)
        }
    }

    private var projectSettingsPresented: Binding<Bool> {
        Binding(
            get: { workspace?.projectSettingsRequested ?? false },
            set: { workspace?.projectSettingsRequested = $0 }
        )
    }

    /// This window's themes and accent: the app-wide settings with the
    /// project's `.ibis.json` overrides laid over them.
    private var appearance: EffectiveAppearance {
        workspace?.appearance ?? settings.appearanceDefaults
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
            lightTheme: appearance.editorLightTheme,
            darkTheme: appearance.editorDarkTheme,
            accent: appearance.accent
        )
    }

    private func openSearchResult(_ url: URL, _ match: SearchMatch) {
        guard let workspace else { return }
        Task {
            let document = workspace.document(for: url)
            await document.loadIfNeeded()
            // The match's offsets came from the *disk* copy; in a buffer with
            // unsaved edits they can land on arbitrary text. Re-anchor against
            // the live buffer rather than blindly selecting the stale range.
            document.pendingSelection = ProjectSearch.resolvedSelection(
                for: match, in: document.text as NSString
            )
            workspace.layout.activePane?.open(document)
        }
    }
}

/// A small floating banner used by the MCP `notify` tool.
private struct MCPBannerView: View {
    let text: String

    @Environment(\.ibisAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(accent)
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
