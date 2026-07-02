import SwiftUI

private enum SidebarMode: Hashable {
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
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace == nil)
                .help("Search in Folder")

                Button {
                    workspace?.layout.splitActive()
                } label: {
                    Label("Split Editor", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(activeDocument == nil)
                .help("Split Editor")

                Button {
                    if let document = activeDocument {
                        Task { await document.save() }
                    }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s")
                .disabled(activeDocument?.isDirty != true)
                .help("Save")
            }
        }
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
                    FileTreeView(workspace: workspace, selection: $selection)
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

    private var editorConfiguration: EditorConfiguration {
        EditorConfiguration(
            fontName: settings.fontName,
            fontSize: settings.fontSize,
            tabWidth: settings.tabWidth,
            usesSoftTabs: settings.usesSoftTabs,
            wordWrap: settings.wordWrap,
            showLineNumbers: settings.showLineNumbers,
            showInvisibles: settings.showInvisibles
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let workspace {
            EditorAreaView(layout: workspace.layout, configuration: editorConfiguration)
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
