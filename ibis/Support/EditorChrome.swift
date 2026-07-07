import CoreGraphics

/// Shared layout constants for the workspace chrome.
enum EditorChrome {
    /// The height of the sidebar's mode switcher header and the editor pane's
    /// tab-bar header. Both columns start at the same Y and place a `Divider()`
    /// immediately below a header of exactly this height, which keeps their
    /// separators aligned pixel-for-pixel across the split view. Keep this the
    /// single source of truth for both headers.
    static let headerHeight: CGFloat = 32

    /// The minimum width of an editor pane. Sized so the pane's tab-bar header
    /// controls — the Source/Preview toggle, Split, and Close Pane — always fit
    /// without clipping; the tab strip scrolls within whatever width is left.
    /// The terminal-resize clamp reserves one of these per open pane so growing
    /// the terminal can never push a pane's controls off-screen.
    static let paneMinWidth: CGFloat = 240
}
