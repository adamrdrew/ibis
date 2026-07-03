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

    var body: some View {
        VStack(spacing: 0) {
            splitView
            if let workspace {
                Divider()
                StatusBarView(git: workspace.git)
            }
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
        .toolbar {
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
                    if let document = activeDocument {
                        Task { await document.save() }
                    }
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
        .background {
            Button("Close Tab") { workspace?.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(activeDocument == nil)
                .hidden()
        }
        // Confirm unsaved changes before the window closes.
        .background {
            WindowCloseGuard { workspace?.confirmWindowClose() ?? true }
        }
        // Expose the frontmost window's workspace and sidebar mode to the menu
        // bar. Scene-scoped (not focus-scoped) so commands like Show Terminal
        // work whenever the window is active, even with no editor focused.
        .focusedSceneValue(\.activeWorkspace, workspace)
        .focusedSceneValue(\.sidebarMode, $sidebarMode)
        .task(id: ref) {
            let workspace = Workspace(rootURL: ref.url, isDirectory: ref.isDirectory)
            self.workspace = workspace
            await workspace.rootNode.loadChildren()
            if !ref.isDirectory {
                selection = workspace.rootNode.id
            }
        }
        .task(id: selection) {
            guard let selection, let workspace else { return }
            let document = workspace.document(for: selection)
            await document.loadIfNeeded()
            workspace.layout.activePane?.open(document)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if let workspace {
            VStack(spacing: 0) {
                Picker("", selection: $sidebarMode) {
                    Label("Files", systemImage: "folder").tag(SidebarMode.files)
                    Label("Search", systemImage: "magnifyingglass").tag(SidebarMode.search)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .padding(.horizontal, 8)
                .frame(height: EditorChrome.headerHeight)

                Divider()

                switch sidebarMode {
                case .files:
                    FileOutlineView(workspace: workspace, selection: $selection)
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
        guard let workspace, let command = settings.agentCommandLine else { return }
        workspace.runAgent(command: command, name: settings.agentName)
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
            layout: workspace.layout,
            configuration: editorConfiguration,
            onCloseTab: { url, pane in workspace.requestCloseTab(url: url, in: pane) }
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
        .onHover { inside in
            if inside {
                (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
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
    }
}
