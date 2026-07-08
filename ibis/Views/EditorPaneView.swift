import SwiftUI

/// A single editor pane: its tab strip plus the editor for the selected tab.
struct EditorPaneView: View {
    let workspace: Workspace
    @Bindable var pane: EditorPane
    let layout: EditorLayout
    let configuration: EditorConfiguration
    var onCloseTab: (OpenDocument, EditorPane) -> Void
    @Environment(AppSettings.self) private var settings

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
                    .fill(Color.ibisAccent)
                    .frame(height: 2)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            // The tab strip takes whatever width is left after the pinned
            // controls and scrolls when the tabs don't fit — so tabs yield
            // space, never the controls.
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)

            trailingControls
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: EditorChrome.headerHeight)
        .background(.bar)
    }

    /// The pane's action cluster, pinned to the trailing edge. `fixedSize` keeps
    /// it at its intrinsic width and the higher layout priority makes the tab
    /// strip (not these controls) give up space when the pane is narrow, so the
    /// buttons never clip or scroll off. The pane's minimum width
    /// (`EditorChrome.paneMinWidth`) guarantees room for this cluster.
    private var trailingControls: some View {
        HStack(spacing: 4) {
            // Source / Preview toggle for renderable files (Markdown / HTML):
            // a single eye button, tinted with the accent when preview is on.
            if let document = pane.selectedDocument, document.isRenderable {
                Button {
                    document.showsPreview.toggle()
                } label: {
                    Image(systemName: document.showsPreview ? "eye.fill" : "eye")
                        .foregroundStyle(document.showsPreview ? AnyShapeStyle(Color.ibisAccent) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(document.showsPreview ? "Show source" : "Show rendered preview")
                .accessibilityLabel("Preview")
                .accessibilityAddTraits(document.showsPreview ? [.isSelected] : [])
            }

            Button {
                layout.activePaneID = pane.id
                layout.splitActive()
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .disabled(pane.selectedDocument == nil)
            .help("Split Editor")
            .accessibilityLabel("Split Editor")

            if hasMultiplePanes {
                Button {
                    workspace.requestClosePane(pane)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Pane")
                .accessibilityLabel("Close Pane")
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    /// A thin banner above the editor (read-only / changed-on-disk warnings).
    private func editorNotice(_ message: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(message)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
            } else if document.isRenderable, document.showsPreview {
                PreviewView(
                    text: document.text,
                    isHTML: document.format == .html,
                    fileURL: document.url,
                    accessRoot: workspace.rootURL
                )
                .id(document.id)
            } else {
                VStack(spacing: 0) {
                    if let reason = document.readOnlyReason {
                        editorNotice(reason, systemImage: "lock.fill")
                    } else if document.isFileMissing {
                        editorNotice(
                            "This file was moved or deleted on disk. Saving will recreate it here.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    } else if document.hasExternalChanges {
                        editorNotice(
                            "This file changed on disk. Saving will overwrite those changes.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                    CodeEditorView(
                        document: document,
                        configuration: configuration,
                        onActivate: { layout.activePaneID = pane.id },
                        focusRequest: pane.focusToken,
                        agentName: settings.agentName,
                        onSendToAgent: { workspace.sendToAgent($0) }
                    )
                }
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
