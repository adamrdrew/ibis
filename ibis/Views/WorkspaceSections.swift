import SwiftUI

/// The workspace toolbar is its own observation boundary: terminal action state,
/// agent settings, and the selected action no longer invalidate the entire
/// navigation/editor hierarchy.
struct WorkspaceToolbar: ToolbarContent {
    let workspace: Workspace?
    let settings: AppSettings
    @Binding var sidebarMode: SidebarMode
    @Binding var selectedActionName: String?
    let openAgent: () -> Void

    var body: some ToolbarContent {
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
                .disabled(workspace.terminal.isActionRunning)

                Button {
                    if workspace.terminal.isActionRunning {
                        workspace.stopProjectAction()
                    } else if let action = selectedAction(in: workspace) {
                        workspace.runProjectAction(action)
                    }
                } label: {
                    Label(
                        workspace.terminal.isActionRunning ? "Stop Action" : "Run Action",
                        systemImage: workspace.terminal.isActionRunning ? "stop.fill" : "play.fill"
                    )
                }
                .tint(workspace.terminal.isActionRunning ? .red : nil)
                .help(workspace.terminal.isActionRunning
                      ? "Stop the running action"
                      : "Run: \(selectedAction(in: workspace)?.command ?? "")")
            }
        }

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
            Button { sidebarMode = .search } label: {
                Label("Search in Folder", systemImage: "magnifyingglass")
            }
            .disabled(workspace == nil)
            .help("Search in Folder (⇧⌘F)")

            Button { workspace?.layout.splitActive() } label: {
                Label("Split Editor", systemImage: "rectangle.split.2x1")
            }
            .disabled(workspace?.activeDocument == nil)
            .help("Split Editor (⌘\\)")

            Button {
                if let workspace { Task { await workspace.saveActiveDocument() } }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(workspace?.activeDocument?.isDirty != true)
            .help("Save (⌘S)")

            Button { workspace?.toggleTerminal() } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .disabled(workspace == nil)
            .help("Show or Hide Terminal (⌃`)")

            Button(action: openAgent) {
                Label("Open \(settings.agentName)", systemImage: "sparkles")
            }
            .disabled(workspace == nil || settings.agentCommandLine == nil)
            .help("Run \(settings.agentName) in a terminal (⌃⇧A)")
        }
    }

    private func selectedAction(in workspace: Workspace) -> ProjectConfig.Action? {
        workspace.availableActions.first { $0.name == selectedActionName }
            ?? workspace.availableActions.first
    }
}

/// The file/search sidebar observes only sidebar state and file/search models.
struct WorkspaceSidebar: View {
    let workspace: Workspace?
    @Binding var selection: FileNode.ID?
    @Binding var mode: SidebarMode
    let searchModel: ProjectSearchModel
    let onOpenSearchResult: (URL, SearchMatch) -> Void

    var body: some View {
        if let workspace {
            VStack(spacing: 0) {
                Picker("Sidebar Mode", selection: $mode) {
                    Label("Files", systemImage: "folder").tag(SidebarMode.files)
                    Label("Search", systemImage: "magnifyingglass").tag(SidebarMode.search)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .padding(.horizontal, 8)
                .frame(height: EditorChrome.headerHeight)

                Divider()

                switch mode {
                case .files:
                    FileOutlineView(workspace: workspace, selection: $selection)
                        .overlay {
                            if workspace.rootIsEmpty {
                                ContentUnavailableView {
                                    Label("Empty Folder", systemImage: "folder")
                                } description: {
                                    Text("Create a file with ⌘N, or drop files here.")
                                }
                                .allowsHitTesting(false)
                            }
                        }
                case .search:
                    ProjectSearchView(
                        model: searchModel,
                        root: workspace.rootURL,
                        onOpen: onOpenSearchResult
                    )
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The editor/terminal region is isolated from sheets, banners, sidebar state,
/// and other window-level concerns. The `AnyLayout` and always-mounted terminal
/// subtree preserve SwiftTerm process identity and scrollback.
struct WorkspaceDetail: View {
    let workspace: Workspace?
    let settings: AppSettings
    let configuration: EditorConfiguration
    @Binding var terminalDragBase: CGFloat?

    var body: some View {
        if let workspace {
            GeometryReader { proxy in
                let trailing = settings.terminalPlacement == .trailing
                let isVisible = workspace.terminal.isVisible
                let layout = trailing
                    ? AnyLayout(HStackLayout(spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                let handleWidth: CGFloat = 6
                let paneCount = max(1, workspace.layout.panes.count)
                let editorReserve = EditorChrome.paneMinWidth * CGFloat(paneCount)
                let maxWidth = max(200, min(proxy.size.width * 0.8,
                                            proxy.size.width - editorReserve - handleWidth))
                let maxHeight = max(120, proxy.size.height - 140)
                let width = min(max(200, workspace.terminal.dockWidth), maxWidth)
                let height = min(max(80, workspace.terminal.dockHeight), maxHeight)
                let editorWidth = max(0, proxy.size.width - handleWidth - width)

                layout {
                    EditorAreaView(
                        workspace: workspace,
                        layout: workspace.layout,
                        configuration: configuration,
                        onCloseTab: { document, pane in
                            workspace.requestCloseTab(document, in: pane)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: trailing && isVisible ? editorWidth : nil)

                    if isVisible {
                        SplitDivider(
                            vertical: trailing,
                            onChanged: { translation in
                                dragTerminal(
                                    workspace, translation: translation, trailing: trailing,
                                    maxWidth: maxWidth, maxHeight: maxHeight
                                )
                            },
                            onEnded: {
                                terminalDragBase = nil
                                workspace.persistLayoutState()
                            },
                            accessibilityLabel: "Resize Terminal",
                            onAdjust: { step in
                                adjustTerminal(
                                    workspace, step: step, trailing: trailing,
                                    maxWidth: maxWidth, maxHeight: maxHeight
                                )
                                workspace.persistLayoutState()
                            }
                        )
                    }

                    TerminalDockView(workspace: workspace, dock: workspace.terminal)
                        .frame(width: trailing ? width : nil, height: trailing ? nil : height)
                        .frame(
                            width: trailing ? (isVisible ? width : 0) : nil,
                            height: trailing ? nil : (isVisible ? height : 0)
                        )
                        .clipped()
                        .allowsHitTesting(isVisible)
                }
            }
            .navigationTitle(workspace.displayName)
            .navigationSubtitle(workspace.activeDocument?.name ?? "")
            .navigationDocument(workspace.activeDocument?.url ?? workspace.rootURL)
        } else {
            ContentUnavailableView(
                "No File Open",
                systemImage: "doc.text",
                description: Text("Select a file from the sidebar to start editing.")
            )
        }
    }

    private func dragTerminal(
        _ workspace: Workspace, translation: CGFloat, trailing: Bool,
        maxWidth: CGFloat, maxHeight: CGFloat
    ) {
        let current = trailing ? workspace.terminal.dockWidth : workspace.terminal.dockHeight
        let base = terminalDragBase ?? current
        if terminalDragBase == nil { terminalDragBase = base }
        if trailing {
            workspace.terminal.dockWidth = min(max(200, base - translation), maxWidth)
        } else {
            workspace.terminal.dockHeight = min(max(80, base - translation), maxHeight)
        }
    }

    private func adjustTerminal(
        _ workspace: Workspace, step: CGFloat, trailing: Bool,
        maxWidth: CGFloat, maxHeight: CGFloat
    ) {
        if trailing {
            workspace.terminal.dockWidth = min(max(200, workspace.terminal.dockWidth + step), maxWidth)
        } else {
            workspace.terminal.dockHeight = min(max(80, workspace.terminal.dockHeight + step), maxHeight)
        }
    }
}

/// Hidden key-window controls take precedence over menu equivalents without
/// making the entire workspace view observe document dirtiness or font size.
struct WorkspaceKeyboardShortcuts: View {
    let workspace: Workspace?
    let activeDocument: OpenDocument?
    let settings: AppSettings

    var body: some View {
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
}
