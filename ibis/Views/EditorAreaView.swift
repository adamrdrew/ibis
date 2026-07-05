import SwiftUI

/// Hosts the workspace's editor panes as resizable vertical slices.
struct EditorAreaView: View {
    let workspace: Workspace
    @Bindable var layout: EditorLayout
    let configuration: EditorConfiguration
    var onCloseTab: (OpenDocument, EditorPane) -> Void

    var body: some View {
        HSplitView {
            ForEach(layout.panes) { pane in
                EditorPaneView(workspace: workspace, pane: pane, layout: layout, configuration: configuration, onCloseTab: onCloseTab)
                    .frame(minWidth: 240)
                    // Persist/restore the split's pane widths. Inside a pane
                    // (not on the HSplitView) so the bridge can find the
                    // backing NSSplitView among its ancestors; one instance
                    // is enough, so only the first pane carries it.
                    .background {
                        if pane.id == layout.panes.first?.id {
                            PaneLayoutBridge(workspace: workspace)
                        }
                    }
            }
        }
    }
}
