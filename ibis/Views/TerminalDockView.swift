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
            .accessibilityLabel("New Terminal")

            Button {
                settings.terminalPlacement = settings.terminalPlacement == .bottom ? .trailing : .bottom
            } label: {
                Image(systemName: settings.terminalPlacement == .bottom ? "rectangle.split.2x1" : "rectangle.split.1x2")
            }
            .buttonStyle(.plain)
            .help(settings.terminalPlacement == .bottom ? "Move Terminal to the Right" : "Move Terminal to the Bottom")
            .accessibilityLabel(settings.terminalPlacement == .bottom ? "Move Terminal to the Right" : "Move Terminal to the Bottom")

            Button {
                dock.isVisible = false
            } label: {
                Image(systemName: settings.terminalPlacement == .bottom ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .help("Hide Terminal")
            .accessibilityLabel("Hide Terminal")
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
                sessionView(session)
            }
        }
    }

    private func sessionView(_ session: TerminalSession) -> some View {
        let isActive = session.id == dock.activeSessionID
        return ZStack {
            TerminalSessionView(
                session: session,
                font: terminalFont,
                shellOverride: shellOverride
            )
            // Action (run) sessions just show their final output when done —
            // no "Shell exited — Restart" affordance (that's for shells/agents).
            // `hasStarted` avoids a flash before the deferred first start runs.
            if session.hasStarted && !session.isRunning && session.role != .run {
                TerminalExitedOverlay(
                    session: session,
                    isActive: isActive,
                    onRestart: { session.restart(shellOverride: shellOverride) }
                )
            }
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
    }
}

/// Shown over a terminal whose shell has exited: a dimmed cover with the exit
/// status and a restart control (also triggered by Return when active).
private struct TerminalExitedOverlay: View {
    let session: TerminalSession
    let isActive: Bool
    let onRestart: () -> Void

    private var statusText: String {
        if let code = session.exitCode, code != 0 {
            return "Shell exited with code \(code)."
        }
        return "Shell exited."
    }

    var body: some View {
        ZStack {
            // A material scrim adapts to light/dark, unlike a hardcoded black wash
            // which reads as a foreign dark overlay in light mode.
            Rectangle()
                .fill(.regularMaterial)

            VStack(spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isActive {
                    Button("Restart", action: onRestart)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.ibisKelly)
                        .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button("Restart", action: onRestart)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.ibisKelly)
                }
            }
            .padding(24)
        }
        .contentShape(Rectangle())
    }
}
