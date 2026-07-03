import SwiftUI

/// A single editor pane: its tab strip plus the editor for the selected tab.
struct EditorPaneView: View {
    let workspace: Workspace
    @Bindable var pane: EditorPane
    let layout: EditorLayout
    let configuration: EditorConfiguration
    var onCloseTab: (OpenDocument, EditorPane) -> Void

    private var isActive: Bool { layout.activePaneID == pane.id }
    private var hasMultiplePanes: Bool { layout.panes.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if isActive && hasMultiplePanes {
                Rectangle()
                    .fill(Color.ibisKelly)
                    .frame(height: 2)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            TabBarView(
                workspace: workspace,
                pane: pane,
                isPaneActive: isActive,
                onSelect: { document in
                    pane.selectedID = document.id
                    layout.activePaneID = pane.id
                },
                onClose: { document in
                    onCloseTab(document, pane)
                }
            )

            Spacer(minLength: 0)

            Button {
                layout.activePaneID = pane.id
                layout.splitActive()
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .disabled(pane.selectedDocument == nil)
            .help("Split Editor")

            if hasMultiplePanes {
                Button {
                    layout.closePane(pane.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Pane")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: EditorChrome.headerHeight)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if let document = pane.selectedDocument {
            if document.isBinary {
                ContentUnavailableView(
                    "Can't Display File",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("This looks like a binary file.")
                )
            } else if let error = document.loadError {
                ContentUnavailableView(
                    "Couldn't Open File",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                CodeEditorView(
                    document: document,
                    configuration: configuration,
                    onActivate: { layout.activePaneID = pane.id },
                    focusRequest: pane.focusToken
                )
                .id(document.id)
            }
        } else {
            ContentUnavailableView(
                "No File Open",
                systemImage: "doc.text",
                description: Text("Select a file from the sidebar.")
            )
        }
    }
}
