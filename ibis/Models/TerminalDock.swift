import Foundation
import Observation

/// The bottom terminal dock for a workspace window: an ordered set of terminal
/// sessions (tabs), the selected one, and whether the dock is showing. Mirrors
/// `EditorLayout`'s shape so it behaves like the rest of the app.
@Observable
@MainActor
final class TerminalDock {
    private(set) var sessions: [TerminalSession] = []
    var activeSessionID: TerminalSession.ID?
    var isVisible = false

    /// Working directory new terminals open in (the workspace root).
    let workingDirectory: URL

    /// Environment from the project's `.ibis.json`, merged into every session.
    var projectEnv: [String: String] = [:]

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID } ?? sessions.first
    }

    /// Creates a new terminal tab rooted at the workspace and focuses it. Pass a
    /// `command` (and `title`) to run something specific, e.g. an agent.
    @discardableResult
    func newSession(command: String? = nil, title: String? = nil, role: TerminalSession.Role = .shell) -> TerminalSession {
        let session = TerminalSession(
            workingDirectory: workingDirectory,
            command: command,
            title: title,
            role: role,
            extraEnvironment: projectEnv
        )
        sessions.append(session)
        activeSessionID = session.id
        return session
    }

    /// Runs a project action in a single reusable "Run" tab (replacing whatever
    /// it was running), so actions never spawn a pile of one-off terminals.
    func runAction(name: String, command: String) {
        if let session = sessions.first(where: { $0.role == .run }) {
            session.run(command: command, title: name, extraEnvironment: projectEnv)
            activeSessionID = session.id
        } else {
            let session = TerminalSession(
                workingDirectory: workingDirectory,
                command: command,
                title: name,
                role: .run,
                extraEnvironment: projectEnv
            )
            sessions.append(session)
            activeSessionID = session.id
        }
        isVisible = true
    }

    /// Closes a terminal tab, terminating its shell and selecting a neighbor.
    /// Hides the dock when the last terminal is closed.
    func closeSession(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminate()
        sessions.remove(at: index)
        if activeSessionID == id {
            activeSessionID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
        if sessions.isEmpty { isVisible = false }
    }

    /// Moves selection to an adjacent terminal tab, wrapping around.
    func selectAdjacent(offset: Int) {
        guard !sessions.isEmpty,
              let current = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        let next = (current + offset + sessions.count) % sessions.count
        activeSessionID = sessions[next].id
    }

    /// Shows the dock, creating a first terminal if there are none.
    func show() {
        if sessions.isEmpty { newSession() }
        isVisible = true
    }

    /// Toggles dock visibility, creating a first terminal when opening empty.
    func toggle() {
        if isVisible {
            isVisible = false
        } else {
            show()
        }
    }

    /// Terminates all shells (workspace teardown).
    func terminateAll() {
        for session in sessions { session.terminate() }
    }
}
