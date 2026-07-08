import SwiftUI
import AppKit
import SwiftTerm

/// Bridges one `TerminalSession`'s live SwiftTerm view into SwiftUI. The
/// `LocalProcessTerminalView` is owned by the session (not created here), so the
/// running shell and its scrollback survive switching between terminal tabs.
struct TerminalSessionView: NSViewRepresentable {
    let session: TerminalSession
    let font: NSFont
    let theme: TerminalTheme
    let shellOverride: String?
    var agentName: String = "Agent"
    var onSendToAgent: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.makeTerminalView(font: font, theme: theme, shellOverride: shellOverride)
        wireSendToAgent(view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if nsView.font.fontName != font.fontName || nsView.font.pointSize != font.pointSize {
            session.apply(font: font)
        }
        // Every mounted session gets this update pass, so a theme change (from
        // Settings or a light/dark appearance flip) fans out to all live
        // terminals; `apply(theme:)` no-ops when the theme is unchanged.
        session.apply(theme: theme)
        wireSendToAgent(nsView)
    }

    private func wireSendToAgent(_ view: LocalProcessTerminalView) {
        guard let ibisView = view as? IbisTerminalView else { return }
        ibisView.onSendToAgent = onSendToAgent
        ibisView.agentName = agentName
    }
}
