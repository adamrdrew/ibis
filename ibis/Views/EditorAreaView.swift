import SwiftUI

/// Hosts the workspace's editor panes as resizable side-by-side slices, using
/// the same `SplitDivider` (and the same width model) as the editor/terminal
/// boundary — so every split in the window looks and drags identically. Pane
/// proportions live in `workspace.paneWidthFractions`, which the splitter reads
/// to lay out and writes as a divider is dragged.
struct EditorAreaView: View {
    let workspace: Workspace
    @Bindable var layout: EditorLayout
    let configuration: EditorConfiguration
    var onCloseTab: (OpenDocument, EditorPane) -> Void

    /// Pane widths (points) captured when a divider drag begins, so each drag
    /// applies its cumulative translation against a stable base instead of
    /// compounding frame-to-frame.
    @State private var dragBaseWidths: [CGFloat]?

    private let dividerWidth: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let count = layout.panes.count
            let content = max(0, proxy.size.width - CGFloat(count - 1) * dividerWidth)
            let widths = PaneWidths.widths(
                content: content, count: count, fractions: workspace.paneWidthFractions
            )
            HStack(spacing: 0) {
                ForEach(Array(layout.panes.enumerated()), id: \.element.id) { index, pane in
                    EditorPaneView(
                        workspace: workspace,
                        pane: pane,
                        layout: layout,
                        configuration: configuration,
                        onCloseTab: onCloseTab
                    )
                    .frame(width: widths[index])

                    if index < count - 1 {
                        SplitDivider(
                            vertical: true,
                            onChanged: { translation in
                                let base = dragBaseWidths ?? widths
                                if dragBaseWidths == nil { dragBaseWidths = base }
                                applyDivider(after: index, base: base, delta: translation)
                            },
                            onEnded: {
                                dragBaseWidths = nil
                                workspace.persistLayoutState()
                            },
                            accessibilityLabel: "Resize Panes",
                            onAdjust: { step in
                                applyDivider(after: index, base: widths, delta: step)
                                workspace.persistLayoutState()
                            }
                        )
                    }
                }
            }
        }
    }

    /// Transfers width between the two panes adjacent to divider `index`, keeping
    /// each at least `EditorChrome.paneMinWidth`, and records the result as
    /// fractions so it survives window/terminal resizes and persistence.
    private func applyDivider(after index: Int, base: [CGFloat], delta: CGFloat) {
        guard base.indices.contains(index), base.indices.contains(index + 1) else { return }
        let minWidth = EditorChrome.paneMinWidth
        let pair = base[index] + base[index + 1]
        // Can't honor the minimum on both if the pair is too small — just split it.
        guard pair >= minWidth * 2 else { return }
        let left = min(max(minWidth, base[index] + delta), pair - minWidth)
        var widths = base
        widths[index] = left
        widths[index + 1] = pair - left
        workspace.paneWidthFractions = PaneWidths.fractions(widths: widths)
    }
}
