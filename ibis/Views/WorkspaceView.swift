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

    /// The persisted terminal dock height, as a `CGFloat` binding for the
    /// resize handle. Writes back to settings so it survives relaunch.
    private var terminalHeightBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(settings.terminalDockHeight) },
            set: { settings.terminalDockHeight = Double($0) }
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
                let isVisible = workspace.terminal.isVisible
                // Clamp so neither the editor nor the terminal can vanish.
                let maxHeight = max(120, proxy.size.height - 140)
                let height = min(max(80, CGFloat(settings.terminalDockHeight)), maxHeight)

                VStack(spacing: 0) {
                    EditorAreaView(layout: workspace.layout, configuration: editorConfiguration)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isVisible {
                        TerminalResizeHandle(height: terminalHeightBinding, maxHeight: maxHeight)
                    }

                    // The dock stays mounted at its real height even when hidden
                    // (outer frame collapses the space, inner frame keeps the
                    // terminal sized) so SwiftTerm views are never detached —
                    // detaching resets their scrollback and kills the illusion
                    // of a persistent session.
                    TerminalDockView(dock: workspace.terminal)
                        .frame(height: height)
                        .frame(height: isVisible ? height : 0)
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

/// A draggable divider between the editor and the terminal dock. Dragging up
/// grows the terminal; the height is clamped so both stay usable.
private struct TerminalResizeHandle: View {
    @Binding var height: CGFloat
    let maxHeight: CGFloat

    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let base = dragStart ?? height
                        if dragStart == nil { dragStart = base }
                        height = min(max(80, base - value.translation.height), maxHeight)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
