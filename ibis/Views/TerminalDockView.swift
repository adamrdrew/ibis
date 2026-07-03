import SwiftUI
import AppKit

/// The bottom terminal dock: a header (tab strip + new/hide controls) aligned to
/// the shared chrome height, then the active terminal session's view.
struct TerminalDockView: View {
    @Bindable var dock: TerminalDock
    @Environment(AppSettings.self) private var settings

    private var terminalFont: NSFont {
        NSFont(name: settings.terminalFontName, size: settings.terminalFontSize)
            ?? .monospacedSystemFont(ofSize: settings.terminalFontSize, weight: .regular)
    }

    private var shellOverride: String? {
        settings.terminalShellPath.isEmpty ? nil : settings.terminalShellPath
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 4) {
            TerminalTabBarView(dock: dock)

            Spacer(minLength: 0)

            Button {
                dock.newSession()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New Terminal")

            Button {
                dock.isVisible = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Hide Terminal")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: EditorChrome.headerHeight)
        .background(.bar)
    }

    // All sessions stay mounted so each terminal keeps its live process and
    // scrollback; only the active one is shown. Detaching/reattaching a
    // SwiftTerm view (as tab-swapping a single slot would) resets its buffer.
    private var content: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            ForEach(dock.sessions) { session in
                TerminalSessionView(
                    session: session,
                    font: terminalFont,
                    shellOverride: shellOverride
                )
                .opacity(session.id == dock.activeSessionID ? 1 : 0)
                .allowsHitTesting(session.id == dock.activeSessionID)
            }
        }
    }
}
