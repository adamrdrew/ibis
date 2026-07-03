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
            }
        }
    }
}
