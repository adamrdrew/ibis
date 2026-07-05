import SwiftUI
import AppKit

/// Persists and restores the editor panes' split widths.
///
/// SwiftUI's `HSplitView` exposes no size API, but it *is* backed by a real
/// `NSSplitView` (verified by dumping the live view tree: the HSplitView
/// renders through a `SystemSplitView` representable hosting an `NSSplitView`
/// with one `_NSSplitViewItemViewWrapper` per pane). This invisible view sits
/// inside the *first* pane, walks up to that ancestor `NSSplitView`, and
/// bridges it to the workspace:
/// - **restore**: once the pane count matches the persisted fractions, applies
///   them via `setPosition(_:ofDividerAt:)` — AppKit treats that like a user
///   drag, so SwiftUI's split accepts it.
/// - **capture**: observes `didResizeSubviewsNotification`, records the new
///   fractions on the workspace, and persists the layout (debounced — the
///   notification fires per pixel during a divider drag).
struct PaneLayoutBridge: NSViewRepresentable {
    let workspace: Workspace

    func makeNSView(context: Context) -> BridgeView { BridgeView(workspace: workspace) }
    func updateNSView(_ view: BridgeView, context: Context) { view.workspace = workspace }

    final class BridgeView: NSView {
        weak var workspace: Workspace?
        private weak var splitView: NSSplitView?
        private var observer: NSObjectProtocol?
        private var persistDebounce: Task<Void, Never>?

        init(workspace: Workspace) {
            self.workspace = workspace
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            persistDebounce?.cancel()
        }

        // Never intercept clicks meant for the pane content above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        // Safety net: if the split wasn't in this view's ancestry yet when the
        // window attach fired (SwiftUI gives no ordering guarantee between
        // adding the background hosting view and re-parenting the pane under
        // the HSplitView's wrapper), keep trying on layout passes — without
        // this, one unlucky ordering would leave width persistence silently
        // dead for the window's whole life.
        override func layout() {
            super.layout()
            attachIfNeeded()
        }

        private func attachIfNeeded() {
            guard window != nil, splitView == nil, let split = editorSplit() else { return }
            splitView = split
            observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: split,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.splitViewDidResize() }
            }
            splitViewDidResize()
        }

        /// The editor `HSplitView`'s backing `NSSplitView`: the nearest
        /// `NSSplitView` ancestor. This view is installed inside an editor pane
        /// (an `_NSSplitViewItemViewWrapper`), so by construction the nearest
        /// such ancestor IS the editor split; the NavigationSplitView's split is
        /// strictly further up and never reached first.
        ///
        /// Deliberately NOT filtered by delegate: SwiftUI backs *both* the
        /// editor `HSplitView` and the NavigationSplitView with an
        /// `NSSplitViewController` (the pane wrappers are its machinery), so a
        /// `delegate is NSSplitViewController` check rejects the editor split
        /// too — which silently disabled width capture entirely.
        private func editorSplit() -> NSSplitView? {
            var candidate = superview
            while let view = candidate {
                if let split = view as? NSSplitView { return split }
                candidate = view.superview
            }
            return nil
        }

        private func splitViewDidResize() {
            applyPendingFractions()
            guard let workspace, let splitView,
                  workspace.restorationComplete, workspace.pendingPaneWidthFractions == nil else { return }
            let fractions = Self.fractions(of: splitView)
            // Only record when AppKit and the model agree on the pane count —
            // mid-split/close layouts would otherwise persist a stale shape.
            guard fractions.count == workspace.layout.panes.count else { return }
            workspace.paneWidthFractions = fractions
            persistDebounce?.cancel()
            persistDebounce = Task { @MainActor [weak workspace] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                workspace?.persistLayoutState()
            }
        }

        /// Applies the restored fractions exactly once, as soon as the split
        /// has grown its restored panes. Runs off the resize notification:
        /// restoring a multi-pane layout adds pane subviews, and each addition
        /// re-layouts the split and fires it.
        private func applyPendingFractions() {
            guard let workspace, workspace.restorationComplete,
                  let fractions = workspace.pendingPaneWidthFractions, let splitView else { return }
            guard fractions.count == workspace.layout.panes.count,
                  fractions.count > 1 else {
                // Nothing applicable (single pane, or the restored tab set no
                // longer matches the saved shape) — stop waiting so resizes
                // start recording.
                workspace.pendingPaneWidthFractions = nil
                return
            }
            guard splitView.arrangedSubviews.count == fractions.count,
                  splitView.bounds.width > 0 else { return } // AppKit still catching up
            workspace.pendingPaneWidthFractions = nil

            let dividers = CGFloat(fractions.count - 1) * splitView.dividerThickness
            let content = splitView.bounds.width - dividers
            var position: CGFloat = 0
            for (index, fraction) in fractions.dropLast().enumerated() {
                position += content * CGFloat(fraction)
                splitView.setPosition(position, ofDividerAt: index)
                position += splitView.dividerThickness
            }
        }

        /// Each pane's share of the total pane width (dividers excluded).
        static func fractions(of split: NSSplitView) -> [Double] {
            fractions(widths: split.arrangedSubviews.map { $0.frame.width })
        }

        /// The pure width→fraction math, split out so it's testable without a
        /// live `NSSplitView`. Empty when there's no width to divide by.
        static func fractions(widths: [CGFloat]) -> [Double] {
            let total = widths.reduce(0, +)
            guard total > 0 else { return [] }
            return widths.map { Double($0 / total) }
        }
    }
}
