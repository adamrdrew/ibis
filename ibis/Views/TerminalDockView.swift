import SwiftUI
import AppKit

/// The bottom terminal dock: a header (tab strip + new/hide controls) aligned to
/// the shared chrome height, then the active terminal session's view.
struct TerminalDockView: View {
    let workspace: Workspace
    @Bindable var dock: TerminalDock
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    private var terminalFont: NSFont {
        NSFont(name: settings.terminalFontName, size: settings.terminalFontSize)
            ?? .monospacedSystemFont(ofSize: settings.terminalFontSize, weight: .regular)
    }

    /// The color theme for the current appearance. Reading `colorScheme` here
    /// means an appearance flip re-runs the session views' update pass, which
    /// re-applies the theme to every live terminal.
    private var terminalTheme: TerminalTheme {
        let isDark = colorScheme == .dark
        let name = isDark ? settings.terminalDarkTheme : settings.terminalLightTheme
        return TerminalThemeCatalog.theme(named: name, isDark: isDark)
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
        // Keyboard focus follows the active tab (only when it was already in a
        // terminal) — hidden tabs stay mounted, so nothing else moves it.
        .onChange(of: dock.activeSessionID) {
            dock.moveKeyboardFocusToActiveTerminalIfNeeded()
        }
        .onAppear {
            // The dock relaunches sessions (Run actions) outside any view pass,
            // so give it live access to the settings shell override — capturing
            // today's value would recreate the frozen-override bug.
            dock.shellOverrideProvider = { [settings] in
                settings.terminalShellPath.isEmpty ? nil : settings.terminalShellPath
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            // Tabs take the leftover width and scroll; the controls are pinned so
            // they never clip when the dock is narrow.
            TerminalTabBarView(dock: dock)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

            trailingControls
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: EditorChrome.headerHeight)
        .background(.bar)
    }

    private var trailingControls: some View {
        HStack(spacing: 4) {
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
        .fixedSize()
        .layoutPriority(1)
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
                theme: terminalTheme,
                shellOverride: shellOverride,
                titleMode: settings.terminalTitleMode,
                agentName: settings.agentName,
                onSendToAgent: { workspace.sendToAgent($0) }
            )
            // Action (run) sessions just show their final output when done —
            // no "Shell exited — Restart" affordance (that's for shells/agents).
            // `hasStarted` avoids a flash before the deferred first start runs.
            if session.hasStarted && !session.isRunning && session.role != .run {
                TerminalExitedOverlay(
                    session: session,
                    onRestart: {
                        workspace.restartTerminalSession(session, settings: settings, shellOverride: shellOverride)
                    }
                )
            }
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .onAppear { wireRestartRequest(session) }
    }

    /// Wires the session's Return-key restart request (fired by the exited
    /// terminal view while it holds keyboard focus — see
    /// `TerminalSession.syncReturnKeyInterception`). Gated on the dock actually
    /// showing and this tab being the active one, so Return can never restart a
    /// collapsed or hidden terminal; the shell override is read from settings at
    /// invocation time so a restart honors a path changed since launch.
    private func wireRestartRequest(_ session: TerminalSession) {
        let workspace = workspace
        session.onRestartRequest = { [weak workspace, weak dock, weak session, settings] in
            guard let workspace, let dock, let session,
                  dock.isVisible, dock.activeSession === session,
                  session.hasStarted, !session.isRunning else { return false }
            let override = settings.terminalShellPath.isEmpty ? nil : settings.terminalShellPath
            workspace.restartTerminalSession(session, settings: settings, shellOverride: override)
            return true
        }
    }
}

/// Shown over a terminal whose shell has exited: a dimmed cover with the exit
/// status and a restart control. Return also restarts, but only while the dead
/// terminal itself holds keyboard focus — that path is the terminal view's
/// `returnKeyAction` (see `TerminalSession.syncReturnKeyInterception`), NOT a
/// `.keyboardShortcut(.return)` on the button, which is window-global and would
/// hijack plain Return from the editor (even with the dock collapsed to zero,
/// since the dock always stays mounted).
private struct TerminalExitedOverlay: View {
    let session: TerminalSession
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
                Button("Restart", action: onRestart)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.ibisAccent)
            }
            .padding(24)
        }
        .contentShape(Rectangle())
    }
}
