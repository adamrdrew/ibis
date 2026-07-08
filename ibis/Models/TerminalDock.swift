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

    /// The dock's size along the resize axis, kept *per window* (not in global
    /// settings, which made every open window resize in lockstep). Height is used
    /// when the dock is at the bottom, width when it's on the trailing edge; both
    /// are stored so flipping placement restores each orientation's own size.
    /// Persisted per workspace root via `WorkspaceStateStore`.
    var dockHeight: CGFloat = 240
    var dockWidth: CGFloat = 480

    /// Working directory new terminals open in (the workspace root).
    let workingDirectory: URL

    /// Environment from the project's `.ibis.json`, merged into every session.
    var projectEnv: [String: String] = [:]

    /// Called when a session's program requests a desktop notification (via an
    /// OSC 9/777 escape sequence). The workspace sets this to show it when the
    /// session isn't on screen.
    @ObservationIgnored var onSessionNotification: ((_ session: TerminalSession, _ title: String?, _ body: String) -> Void)?

    /// Called when a session's program rings the terminal bell (debounced by
    /// the session). The workspace turns it into a desktop notification when
    /// the session isn't on screen — the fallback for programs that never emit
    /// a notification OSC.
    @ObservationIgnored var onSessionBell: ((_ session: TerminalSession) -> Void)?

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID } ?? sessions.first
    }

    /// The reusable action session, if it exists.
    var runSession: TerminalSession? {
        sessions.first { $0.role == .run }
    }

    /// The sessions included in a persisted snapshot: every tab except the
    /// reusable `.run` action tab. The layout fingerprint and the snapshot both
    /// derive from this, so they can never disagree on what counts.
    var persistableSessions: [TerminalSession] {
        sessions.filter { $0.role != .run }
    }

    /// Index into `persistableSessions` of the active tab (-1 for none).
    var activePersistableIndex: Int {
        persistableSessions.firstIndex { $0.id == activeSessionID } ?? -1
    }

    /// Whether a project action is currently running. Stored (not derived from
    /// the session) so the toolbar reliably observes it — SwiftUI toolbars don't
    /// track a value read through nested computed properties across objects.
    private(set) var isActionRunning = false

    /// Stops the running action (terminates the Run session's process).
    func stopAction() {
        runSession?.terminate()
        isActionRunning = false
    }

    /// Creates a new terminal tab rooted at the workspace and focuses it. Pass a
    /// `command` (and `title`) to run something specific, e.g. an agent.
    /// `takeFocus` is false when restoring several tabs at window open, so they
    /// don't fight each other (and the editor) for first responder.
    @discardableResult
    func newSession(
        command: String? = nil,
        title: String? = nil,
        role: TerminalSession.Role = .shell,
        agentSessionID: String? = nil,
        takeFocus: Bool = true
    ) -> TerminalSession {
        let session = TerminalSession(
            workingDirectory: workingDirectory,
            command: command,
            title: title,
            role: role,
            agentSessionID: agentSessionID,
            extraEnvironment: projectEnv
        )
        // Give the freshly opened terminal/agent tab keyboard focus once built.
        if takeFocus { session.wantsFocus = true }
        wireAttentionSignals(session)
        sessions.append(session)
        activeSessionID = session.id
        return session
    }

    /// Runs a project action in a single reusable "Run" tab (replacing whatever
    /// it was running), so actions never spawn a pile of one-off terminals.
    func runAction(name: String, command: String) {
        // Never start a new action while one is running (avoids clobbering the
        // reused view's process state; the toolbar also disables this).
        guard !isActionRunning else { return }

        let session: TerminalSession
        if let existing = sessions.first(where: { $0.role == .run }) {
            session = existing
            session.run(command: command, title: name, extraEnvironment: projectEnv)
        } else {
            session = TerminalSession(
                workingDirectory: workingDirectory,
                command: command,
                title: name,
                role: .run,
                extraEnvironment: projectEnv
            )
            wireAttentionSignals(session)
            sessions.append(session)
        }
        session.onExit = { [weak self] in self?.isActionRunning = false }
        isActionRunning = true
        activeSessionID = session.id
        isVisible = true
    }

    /// Routes a session's attention signals (notification OSCs, the bell) up to
    /// the workspace. Every session gets this, including the reusable Run tab —
    /// a long project action finishing in a backgrounded window is exactly as
    /// notification-worthy as an agent.
    private func wireAttentionSignals(_ session: TerminalSession) {
        session.onNotification = { [weak self, weak session] title, body in
            guard let self, let session else { return }
            self.onSessionNotification?(session, title, body)
        }
        session.onBell = { [weak self, weak session] in
            guard let self, let session else { return }
            self.onSessionBell?(session)
        }
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

    /// Reorders a terminal tab, dropping the tab `fromID` onto the position of
    /// `toID`. Returns `false` when the move can't apply (unknown ids), so the
    /// drop declines instead of animating an accepted no-op. Mirrors
    /// `EditorPane.moveTab`.
    @discardableResult
    func moveSession(fromID: TerminalSession.ID, toID: TerminalSession.ID) -> Bool {
        guard fromID != toID,
              let from = sessions.firstIndex(where: { $0.id == fromID }),
              let to = sessions.firstIndex(where: { $0.id == toID }) else { return false }
        let session = sessions.remove(at: from)
        let insertion = sessions.firstIndex(where: { $0.id == toID }) ?? to
        // Insert before the target when moving left, after it when moving right.
        sessions.insert(session, at: from < to ? insertion + 1 : insertion)
        return true
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
