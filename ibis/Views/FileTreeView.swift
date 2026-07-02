import SwiftUI

/// The sidebar file browser: a hierarchical, lazily-disclosed tree of the
/// workspace's contents. Selection is bound to the enclosing `WorkspaceView`.
struct FileTreeView: View {
    let workspace: Workspace
    @Binding var selection: FileNode.ID?

    var body: some View {
        List(selection: $selection) {
            if workspace.rootNode.isDirectory {
                if let children = workspace.rootNode.children {
                    ForEach(children) { node in
                        FileNodeRow(node: node)
                    }
                }
            } else {
                FileNodeRow(node: workspace.rootNode)
            }
        }
        .listStyle(.sidebar)
    }
}

/// A single row in the file tree. Directories are `DisclosureGroup`s that load
/// their children the first time they expand; files are selectable leaf rows.
private struct FileNodeRow: View {
    @Bindable var node: FileNode

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                if let children = node.children {
                    ForEach(children) { child in
                        FileNodeRow(node: child)
                    }
                }
            } label: {
                label
            }
            .onChange(of: node.isExpanded) { _, isExpanded in
                if isExpanded {
                    Task { await node.loadChildren() }
                }
            }
        } else {
            label
                .tag(node.id)
        }
    }

    private var label: some View {
        Label {
            Text(node.name)
        } icon: {
            Image(systemName: FileIconProvider.symbolName(for: node))
                .foregroundStyle(FileIconProvider.tint(for: node))
        }
    }
}
