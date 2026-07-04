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
    /// project actions execute in.
    enum Role { case shell, agent, run }

    let id = UUID()
    let workingDirectory: URL
    let role: Role

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

    init(
        workingDirectory: URL,
        command: String? = nil,
        title: String? = nil,
        role: Role = .shell,
        extraEnvironment: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.role = role
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

        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.processDelegate = self
        view.font = font
        terminalView = view
        // Start the shell *after* this view-building pass: `startShell` mutates
        // observed state (title/isRunning/exitCode), which must not happen while
        // SwiftUI is reading it to render this same frame.
        let override = shellOverride
        Task { @MainActor [weak self] in
            guard let self, !self.hasStarted else { return }
            self.startShell(shellOverride: override, on: view)
        }
        return view
    }

    /// Applies a new font to the running terminal, if built.
    func apply(font: NSFont) {
        terminalView?.font = font
    }

    /// Restarts the shell in the existing view after it has exited.
    func restart(shellOverride: String?) {
        guard let terminalView, !isRunning else { return }
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
        // For a command (agent / action), run it through a login shell (`-l -c`)
        // so it inherits the user's PATH; otherwise launch an interactive shell.
        let args = command.map { ["-l", "-c", $0] } ?? shell.args
        view.startProcess(
            executable: shell.executable,
            args: args,
            environment: ShellResolver.environment(extra: extraEnvironment),
            execName: shell.execName,
            currentDirectory: workingDirectory.path(percentEncoded: false)
        )
        isRunning = true
        hasStarted = true
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
        onExit?()
    }
}
