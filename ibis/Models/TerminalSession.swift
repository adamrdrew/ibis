import Foundation
import Observation
import AppKit
import SwiftTerm

/// One integrated-terminal instance: a shell running in a pseudo-terminal,
/// rendered by SwiftTerm. Owns (and retains) its `LocalProcessTerminalView` so
/// the shell process and its scrollback survive switching between terminal tabs.
@Observable
@MainActor
final class TerminalSession: Identifiable, LocalProcessTerminalViewDelegate {
    /// What a session is for. The `run` session is a single reusable tab that
    /// project actions execute in. String-backed so persistence stores the role
    /// without hand-mapped literals (only `.shell`/`.agent` are ever persisted).
    enum Role: String, Codable { case shell, agent, run }

    let id = UUID()
    let workingDirectory: URL
    let role: Role

    /// For a Claude agent tab, the stable session UUID this tab was launched with
    /// (`claude --session-id <uuid>`), so window-layout restoration can bring the
    /// conversation back via `claude --resume <uuid>`. Nil for shells and agents
    /// that don't support session resume. Excluded from observation — it's plumbing
    /// for persistence, not UI state.
    @ObservationIgnored var agentSessionID: String?

    /// A specific command to run as a login shell (e.g. an agent or a project
    /// action), or nil for a plain interactive shell. Mutable so the reusable
    /// `run` session can execute successive actions.
    private(set) var command: String?
    /// Extra environment (from the project's `.ibis.json`) merged into the shell.
    var extraEnvironment: [String: String]
    /// The shell override last used, so `run`/`restart` can reuse it.
    @ObservationIgnored private var lastShellOverride: String?
    /// Fallback tab title (before/without a title escape sequence).
    private var defaultTitle: String

    /// Shown in the tab; updated live from the shell's title escape sequences.
    var title: String
    /// False once the shell process exits (until restarted).
    private(set) var isRunning = false
    /// True once the shell has been started at least once, so the "Shell exited"
    /// overlay doesn't flash before the (deferred) first start runs.
    private(set) var hasStarted = false
    /// The shell's exit status, once it has exited (nil while running).
    private(set) var exitCode: Int32?

    /// The live terminal view. AppKit-managed, so excluded from observation;
    /// built lazily the first time the tab is shown.
    @ObservationIgnored private(set) var terminalView: LocalProcessTerminalView?

    /// Called when the shell process exits (used by the action runner).
    @ObservationIgnored var onExit: (() -> Void)?

    /// Called when the running program explicitly requests a desktop notification
    /// via an OSC escape sequence (OSC 777 `notify;title;body`, or iTerm2-style
    /// OSC 9 `message`). This is the program telling us it wants the human — the
    /// reliable, cross-terminal signal (Claude Code, Codex, Gemini CLI, …), not a
    /// heuristic. The dock forwards it to the workspace, which shows it only when
    /// this session isn't the one being looked at.
    @ObservationIgnored var onNotification: ((_ title: String?, _ body: String) -> Void)?

    /// Called (debounced) when the program rings the terminal bell — the
    /// fallback attention signal for programs that never emit a notification
    /// OSC: Gemini CLI outside its recognized terminals, Claude Code's
    /// `terminal_bell` channel, and classic long-running CLIs.
    @ObservationIgnored var onBell: (() -> Void)?

    /// When an OSC notification was last forwarded, so the bell that rides along
    /// with one (Claude Code's `iterm2_with_bell` sends OSC 9 + BEL back to
    /// back) doesn't become a second, poorer desktop notification.
    @ObservationIgnored private var notificationForwardedAt: Date?
    /// When a bell was last forwarded, rate-limiting bell storms (a binary
    /// `cat` to the terminal can ring hundreds of times a second).
    @ObservationIgnored private var bellForwardedAt: Date?

    /// Called when the process exits naturally, with its exit code and how long
    /// it ran. Window restore uses this to detect a Claude `--resume` that failed
    /// because the old session is gone, so it can recover into a fresh session.
    /// Its presence is the "recovery armed" state: the recovery handler nils it
    /// out once it declines to act, so a later exit can't re-trigger it.
    @ObservationIgnored var onProcessExit: ((_ exitCode: Int32?, _ ranFor: TimeInterval) -> Void)?

    /// When the current process was started, to measure a quick failure.
    @ObservationIgnored private var startedAt: Date?

    /// Requests that this session's terminal view take keyboard focus once it is
    /// built and in a window. Set when a new terminal or agent tab is opened, so
    /// the user can start typing immediately.
    @ObservationIgnored var wantsFocus = false

    init(
        workingDirectory: URL,
        command: String? = nil,
        title: String? = nil,
        role: Role = .shell,
        agentSessionID: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.role = role
        self.agentSessionID = agentSessionID
        self.extraEnvironment = extraEnvironment
        let resolvedTitle = title ?? workingDirectory.lastPathComponent
        self.defaultTitle = resolvedTitle
        self.title = resolvedTitle
    }

    /// Runs a command in this (reusable) session, replacing any running process.
    /// Used by the project action runner so all actions share one Run tab.
    func run(command: String, title: String, extraEnvironment: [String: String]) {
        self.command = command
        self.defaultTitle = title
        self.title = title
        self.extraEnvironment = extraEnvironment
        if let terminalView {
            if isRunning { terminate() }
            startShell(shellOverride: lastShellOverride, on: terminalView)
        }
        // If the view isn't built yet, makeTerminalView starts `command` on build.
    }

    /// Returns the terminal view, creating it and starting the shell on first
    /// call. `font`, `theme`, and `shellOverride` come from settings; the font
    /// and theme are applied on the initial build and updated live afterward via
    /// `apply(font:)` / `apply(theme:)`.
    func makeTerminalView(font: NSFont, theme: TerminalTheme, shellOverride: String?) -> LocalProcessTerminalView {
        if let terminalView { return terminalView }

        // Make the mouse wheel scroll full-screen TUIs (Claude Code, less, vim…).
        TerminalScrollFix.installIfNeeded()

        let view = IbisTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.processDelegate = self
        view.font = font
        apply(theme: theme, to: view)
        let terminal = view.getTerminal()
        // Match SwiftTerm's release behavior in debug builds: `silentLog`
        // defaults to false under DEBUG, printing "Unknown OSC code: 133" for
        // every shell-integration prompt mark the shell or an agent TUI emits —
        // one console line per keystroke.
        terminal.silentLog = true
        registerNotificationHandlers(on: terminal)
        view.onBell = { [weak self] in self?.bellRang() }
        terminalView = view
        // Start the shell *after* this view-building pass: `startShell` mutates
        // observed state (title/isRunning/exitCode), which must not happen while
        // SwiftUI is reading it to render this same frame.
        let override = shellOverride
        Task { @MainActor [weak self] in
            guard let self, !self.hasStarted else { return }
            self.startShell(shellOverride: override, on: view)
            // Now that the view is built and (this hop) in the window, honor a
            // pending focus request from opening a new terminal / agent tab.
            if self.wantsFocus {
                self.wantsFocus = false
                view.window?.makeFirstResponder(view)
            }
        }
        return view
    }

    /// Applies a new font to the running terminal, if built.
    func apply(font: NSFont) {
        terminalView?.font = font
    }

    /// The theme currently installed on the view, so a redundant re-apply (every
    /// SwiftUI update pass calls through) is cheap to skip.
    @ObservationIgnored private var appliedThemeName: String?

    /// Applies a color theme to the running terminal, if built. Mutates the
    /// existing view in place — never rebuilds it — so the live process and its
    /// scrollback survive (detaching a SwiftTerm view resets its buffer).
    func apply(theme: TerminalTheme) {
        guard let terminalView, theme.name != appliedThemeName else { return }
        apply(theme: theme, to: terminalView)
    }

    private func apply(theme: TerminalTheme, to view: LocalProcessTerminalView) {
        // `installColors` resets the palette and the native fg/bg, so it must run
        // first; the explicit fg/bg/cursor/selection overrides then take effect.
        if theme.hasValidPalette {
            view.installColors(theme.ansi.map(\.swiftTermColor))
        }
        view.nativeBackgroundColor = theme.background.nsColor
        view.nativeForegroundColor = theme.foreground.nsColor
        view.caretColor = theme.cursor.nsColor
        view.caretTextColor = theme.cursorText?.nsColor
        view.selectedTextBackgroundColor = theme.selection.nsColor
        appliedThemeName = theme.name
    }

    /// Restarts the shell in the existing view after it has exited. Pass
    /// `command` to replace what the tab runs — an agent tab must restart via
    /// `--resume` once its session exists on disk, because re-running its
    /// original `--session-id` launch is rejected ("Session ID already in use").
    func restart(shellOverride: String?, command: String? = nil) {
        guard let terminalView, !isRunning else { return }
        if let command { self.command = command }
        startShell(shellOverride: shellOverride, on: terminalView)
    }

    /// Terminates the shell process (Stop, explicit close, workspace teardown).
    /// SwiftTerm's `terminate()` cancels its process-exit monitor, so
    /// `processTerminated` never fires for a process killed this way — the exit
    /// state must be settled here, synchronously. The `isRunning` guard also
    /// keeps a second terminate from SIGTERM-ing a dead shell's PID, which the
    /// kernel may have already recycled for an unrelated process.
    func terminate() {
        guard isRunning else { return }
        isRunning = false
        exitCode = nil
        terminalView?.terminate()
        onExit?()
    }

    private func startShell(shellOverride: String?, on view: LocalProcessTerminalView) {
        let shell = ShellResolver.resolve(override: shellOverride)
        lastShellOverride = shellOverride
        title = defaultTitle
        exitCode = nil
        // For a command (agent / action), run it through an interactive login
        // shell (`-l -i -c`) so it sources the user's full profile — not just the
        // login files but also the interactive rc (e.g. `~/.zshrc`), where PATH
        // and per-session env like Claude's Vertex config (CLAUDE_CODE_USE_VERTEX,
        // ANTHROPIC_VERTEX_PROJECT_ID, CLOUD_ML_REGION) commonly live. A plain
        // `-l -c` shell skips `~/.zshrc`, so an agent launched that way misses
        // those vars even though a normal (interactive) terminal tab sees them.
        // `-c` still runs the command and exits, so exit/resume handling is
        // unchanged. Otherwise launch a plain interactive shell.
        let args = command.map { ["-l", "-i", "-c", $0] } ?? shell.args
        view.startProcess(
            executable: shell.executable,
            args: args,
            environment: ShellResolver.environment(extra: extraEnvironment),
            execName: shell.execName,
            currentDirectory: workingDirectory.path(percentEncoded: false)
        )
        startedAt = Date()
        isRunning = true
        hasStarted = true
    }

    /// Writes a yellow notice into the terminal and re-runs the tab in the same
    /// view. With no arguments the current command is retried verbatim (a
    /// `--resume` rejected while the previous window's agent finished shutting
    /// down); pass `command`/`agentSessionID` to relaunch as a fresh session
    /// after a resume whose conversation is gone for good.
    func relaunch(notice: String, command: String? = nil, agentSessionID: String? = nil) {
        guard let terminalView, !isRunning else { return }
        if let command { self.command = command }
        if let agentSessionID { self.agentSessionID = agentSessionID }
        // Notice line first, then the relaunched command's output follows below.
        terminalView.feed(text: "\r\n\u{1b}[33m" + notice + "\u{1b}[0m\r\n")
        startShell(shellOverride: lastShellOverride, on: terminalView)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { self.title = trimmed }
    }

    /// Intercepts the OSC notification escape sequences a program uses to ask for
    /// the human's attention, forwarding each to `onNotification`. User handlers
    /// take precedence over SwiftTerm's built-ins, so both routes are ours:
    ///  - **OSC 777** `notify;<title>;<body>` — the WezTerm/VTE convention.
    ///  - **OSC 9** `<message>` — the iTerm2 convention (what Claude Code emits
    ///    once it thinks it's in iTerm2). OSC 9 is also ConEmu's progress channel
    ///    (`4;<state>;<pct>`), which carries no message, so those are ignored.
    private func registerNotificationHandlers(on terminal: Terminal) {
        terminal.registerOscHandler(code: 777) { [weak self] data in
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            let parts = text.components(separatedBy: ";")
            guard parts.count >= 3, parts[0] == "notify" else { return }
            let title = parts[1]
            let body = parts[2...].joined(separator: ";")
            self?.forwardNotification(title: title.isEmpty ? nil : title, body: body)
        }
        terminal.registerOscHandler(code: 9) { [weak self] data in
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            // ConEmu's extensions share OSC 9 with iTerm2-style notifications
            // but always lead with a numeric selector (`9;4;<state>;<pct>` is
            // the progress bar Claude Code emits each turn on newer iTerms). A
            // leading all-digit field is never notification text, so drop it.
            if let semi = text.firstIndex(of: ";"), semi != text.startIndex,
               text[..<semi].allSatisfy(\.isNumber) { return }
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            self?.forwardNotification(title: nil, body: body)
        }
    }

    private func forwardNotification(title: String?, body: String) {
        notificationForwardedAt = Date()
        onNotification?(title, body)
    }

    /// Forwards a bell, unless it arrived on the heels of an explicit OSC
    /// notification (the same alert, told twice) or of another bell (a storm).
    private func bellRang() {
        let now = Date()
        if let recent = notificationForwardedAt, now.timeIntervalSince(recent) < 2 { return }
        if let recent = bellForwardedAt, now.timeIntervalSince(recent) < 5 { return }
        bellForwardedAt = now
        onBell?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Already settled by `terminate()` (or never started): nothing to do.
        guard isRunning else { return }
        self.exitCode = exitCode
        isRunning = false
        let ranFor = startedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        onExit?()
        onProcessExit?(exitCode, ranFor)
    }
}
