import SwiftUI
import AppKit

/// The one draggable divider used everywhere the workspace splits — between
/// editor panes and between the editor and the terminal — so every boundary
/// looks and resizes identically.
///
/// It reports the signed translation (in points, along the resize axis) since
/// the drag began. Callers capture their own base sizes on the first callback
/// and apply the delta, which lets the same divider drive both a fraction
/// transfer between panes and an absolute terminal width. The drag is measured
/// in the *global* space, not the local one: the divider slides as the layout it
/// resizes moves under the pointer, so a local translation would be measured
/// against a frame moving under it and feed back into the value (jumpy). Global
/// coordinates stay put, so the delta is stable.
struct SplitDivider: View {
    /// True for a vertical bar between side-by-side columns (column-resize
    /// cursor); false for a horizontal bar between stacked rows (row-resize).
    let vertical: Bool
    /// Signed translation along the resize axis since the gesture began.
    var onChanged: (CGFloat) -> Void
    /// The drag (or an accessibility adjust) settled — a good time to persist.
    var onEnded: () -> Void
    var accessibilityLabel: String = "Resize"
    /// A discrete +/- step (points) from an accessibility adjustable action.
    var onAdjust: (CGFloat) -> Void = { _ in }

    var body: some View {
        let line = Rectangle().fill(Color(nsColor: .separatorColor))
        Group {
            if vertical { line.frame(width: 1) } else { line.frame(height: 1) }
        }
        .frame(width: vertical ? 6 : nil, height: vertical ? nil : 6)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .contentShape(Rectangle())
        // `pointerStyle` shows the resize cursor only while over the handle and
        // restores it automatically — unlike a manual NSCursor push/pop in
        // onHover, which leaks a pushed cursor if the handle is unmounted while
        // hovered (e.g. ⌃` hiding the terminal).
        .pointerStyle(vertical ? .columnResize : .rowResize)
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    onChanged(vertical ? value.translation.width : value.translation.height)
                }
                .onEnded { _ in onEnded() }
        )
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onAdjust(24)
            case .decrement: onAdjust(-24)
            @unknown default: break
            }
            onEnded()
        }
    }
}

/// Pure pane-width math, shared by the splitter and its tests.
enum PaneWidths {
    /// Each width as a fraction of the total (dividers already excluded). Empty
    /// when there's no width to divide by, so a pre-layout zero size is rejected
    /// rather than producing NaNs.
    static func fractions(widths: [CGFloat]) -> [Double] {
        let total = widths.reduce(0, +)
        guard total > 0 else { return [] }
        return widths.map { Double($0 / total) }
    }

    /// Distributes `content` points across `count` panes using `fractions` when
    /// they match the count (and sum positively), else an equal split. Always
    /// returns exactly `count` non-negative widths that sum to `content`.
    static func widths(content: CGFloat, count: Int, fractions: [Double]?) -> [CGFloat] {
        guard count > 0 else { return [] }
        let safe = max(0, content)
        if let fractions, fractions.count == count {
            let sum = fractions.reduce(0, +)
            if sum > 0 { return fractions.map { safe * CGFloat($0 / sum) } }
        }
        return Array(repeating: safe / CGFloat(count), count: count)
    }
}
