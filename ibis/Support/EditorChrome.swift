import CoreGraphics

/// Shared layout constants for the workspace chrome.
enum EditorChrome {
    /// The height of the sidebar's mode switcher header and the editor pane's
    /// tab-bar header. Both columns start at the same Y and place a `Divider()`
    /// immediately below a header of exactly this height, which keeps their
    /// separators aligned pixel-for-pixel across the split view. Keep this the
    /// single source of truth for both headers.
    static let headerHeight: CGFloat = 32
}
