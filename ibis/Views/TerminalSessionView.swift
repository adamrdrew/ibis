import SwiftUI
import AppKit
import SwiftTerm

/// Bridges one `TerminalSession`'s live SwiftTerm view into SwiftUI. The
/// `LocalProcessTerminalView` is owned by the session (not created here), so the
/// running shell and its scrollback survive switching between terminal tabs.
struct TerminalSessionView: NSViewRepresentable {
    let session: TerminalSession
    let font: NSFont
    let shellOverride: String?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.makeTerminalView(font: font, shellOverride: shellOverride)
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if nsView.font.fontName != font.fontName || nsView.font.pointSize != font.pointSize {
            session.apply(font: font)
        }
    }
}
