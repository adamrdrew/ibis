import SwiftUI

/// Hosts the workspace's editor panes as resizable vertical slices.
struct EditorAreaView: View {
    @Bindable var layout: EditorLayout
    let configuration: EditorConfiguration
    var onCloseTab: (OpenDocument, EditorPane) -> Void

    var body: some View {
        HSplitView {
            ForEach(layout.panes) { pane in
                EditorPaneView(pane: pane, layout: layout, configuration: configuration, onCloseTab: onCloseTab)
                    .frame(minWidth: 240)
            }
        }
    }
}
