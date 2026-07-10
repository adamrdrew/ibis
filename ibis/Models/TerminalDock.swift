import Foundation
import Observation
import AppKit

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

    /// Ad-hoc environment injected into every session launched from now on, on
    /// top of `projectEnv` (winning on key collisions) — the seam for values the
    /// app computes at runtime rather than reads from the project config, e.g.
    /// an `IBIS_MCP_TOKEN` for agent sessions. Already-running sessions are
    /// unaffected.
    var extraLaunchEnvironment: [String: String] = [:]

    /// The environment handed to newly launched sessions: the project's
    /// `.ibis.json` env plus the ad-hoc entries (which win on collisions).
    var launchEnvironment: [String: String] {
        projectEnv.merging(extraLaunchEnvironment) { _, adHoc in adHoc }
    }

    /// Supplies the *current* Settings shell override (nil for none) whenever a
    /// session is (re)launched, so re-run actions pick up a shell path changed
    /// in Settings — unlike a value captured at first launch. Wired by
    /// `TerminalDockView`, which owns the settings access.
    @ObservationIgnored var shellOverrideProvider: (() -> String?)?

    /// The settings shell override right now (nil when none is configured or
    /// the provider isn't wired yet).
    private var currentShellOverride: String? {
        shellOverrideProvider?() ?? nil
    }

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
            extraEnvironment: launchEnvironment
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
        } else {
            session = TerminalSession(workingDirectory: workingDirectory, role: .run)
            wireAttentionSignals(session)
            sessions.append(session)
        }
        // One retarget path for both branches, so a fresh Run tab records the
        // current shell override and env exactly like a reused one (with no
        // view yet, `run` just sets the fields; the build starts the process).
        session.run(
            command: command,
            title: name,
            extraEnvironment: launchEnvironment,
            shellOverride: currentShellOverride
        )
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

    /// Keeps keyboard focus with the active terminal tab. Every session's view
    /// stays mounted (hidden ones at opacity 0), so switching tabs doesn't move
    /// first responder by itself — keystrokes would keep flowing to the hidden
    /// tab's PTY, and its program would keep being told it's focused. Called by
    /// `TerminalDockView` whenever `activeSessionID` changes: if focus currently
    /// sits inside one of this dock's terminal views, it moves to the newly
    /// active session's view (SwiftTerm's responder overrides then send the DEC
    /// 1004 focus-out/in to the outgoing and incoming programs). Focus that's
    /// elsewhere (editor, file tree) is never stolen.
    func moveKeyboardFocusToActiveTerminalIfNeeded() {
        guard let active = activeSession else { return }
        let terminalViews = sessions.compactMap(\.terminalView)
        guard let window = terminalViews.compactMap(\.window).first,
              let responder = window.firstResponder else { return }
        let focusIsInATerminal = terminalViews.contains { view in
            responder === view || ((responder as? NSView)?.isDescendant(of: view) ?? false)
        }
        guard focusIsInATerminal else { return }
        if let view = active.terminalView, view.window === window {
            window.makeFirstResponder(view)
        } else {
            // The active tab's view isn't built yet (first show): have it take
            // focus once `makeTerminalView` runs.
            active.wantsFocus = true
        }
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
