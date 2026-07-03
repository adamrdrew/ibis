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
    let id = UUID()
    let workingDirectory: URL

    /// Shown in the tab; updated live from the shell's title escape sequences.
    var title: String
    /// False once the shell process exits (until restarted).
    private(set) var isRunning = false

    /// The live terminal view. AppKit-managed, so excluded from observation;
    /// built lazily the first time the tab is shown.
    @ObservationIgnored private(set) var terminalView: LocalProcessTerminalView?

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
        self.title = workingDirectory.lastPathComponent
    }

    /// Returns the terminal view, creating it and starting the shell on first
    /// call. `font` and `shellOverride` come from settings (only used on the
    /// initial build; later font changes are applied via `apply(font:)`).
    func makeTerminalView(font: NSFont, shellOverride: String?) -> LocalProcessTerminalView {
        if let terminalView { return terminalView }

        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.processDelegate = self
        view.font = font
        startShell(shellOverride: shellOverride, on: view)
        terminalView = view
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

    /// Terminates the shell process (on explicit close or workspace teardown).
    func terminate() {
        terminalView?.terminate()
        isRunning = false
    }

    private func startShell(shellOverride: String?, on view: LocalProcessTerminalView) {
        let shell = ShellResolver.resolve(override: shellOverride)
        title = workingDirectory.lastPathComponent
        view.startProcess(
            executable: shell.executable,
            args: shell.args,
            environment: ShellResolver.environment(),
            execName: shell.execName,
            currentDirectory: workingDirectory.path(percentEncoded: false)
        )
        isRunning = true
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { self.title = trimmed }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
    }
}
