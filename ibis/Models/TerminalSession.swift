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
    /// call. `font` and `shellOverride` come from settings (only used on the
    /// initial build; later font changes are applied via `apply(font:)`).
    func makeTerminalView(font: NSFont, shellOverride: String?) -> LocalProcessTerminalView {
        if let terminalView { return terminalView }

        // Make the mouse wheel scroll full-screen TUIs (Claude Code, less, vim…).
        TerminalScrollFix.installIfNeeded()

        let view = IbisTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.processDelegate = self
        view.font = font
        // Match SwiftTerm's release behavior in debug builds: `silentLog`
        // defaults to false under DEBUG, printing "Unknown OSC code: 133" for
        // every shell-integration prompt mark the shell or an agent TUI emits —
        // one console line per keystroke.
        view.getTerminal().silentLog = true
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
