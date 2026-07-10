import Foundation
import Observation

/// A tiny hand-off point for workspaces that need a new window.
///
/// AppKit-level events (Finder / CLI opens) arrive in `AppDelegate`, which can't
/// call SwiftUI's `openWindow` directly. Instead it enqueues here, and the
/// frontmost SwiftUI window observes and drains the queue, opening windows.
@Observable
final class LaunchRouter {
    static let shared = LaunchRouter()

    private(set) var pending: [WorkspaceRef] = []

    /// Roots (by canonical path) that should launch the configured agent once
    /// their window opens. Kept separate from `WorkspaceRef` so the window's
    /// restoration identity is unchanged and restored windows never re-run the
    /// agent. Consumed exactly once by the target workspace.
    private var pendingAgentLaunches: Set<String> = []

    /// Bumped whenever an agent launch is requested, so an *already-open* window
    /// for the target folder can observe it and consume the request itself — a
    /// new window's `.task` alone would miss it (opening an existing window just
    /// focuses it), stranding the flag to later fire on an unrelated open.
    private(set) var agentLaunchSignal = 0

    /// Observable signal that a drain is needed. Views observe this in `onChange`.
    var pendingCount: Int { pending.count }

    /// The most recent `openWindow` action, captured by a drain view. SwiftUI
    /// environment actions stay valid app-wide after capture, so the router can
    /// open a window itself when no drain view is alive.
    @ObservationIgnored private var windowOpener: ((WorkspaceRef) -> Void)?

    /// How many drain views (Welcome / workspace windows) are currently alive.
    @ObservationIgnored private var drainObservers = 0

    private init() {}

    /// A drain view came on screen: remember how to open windows, and hand it
    /// anything already queued — `onChange(of: pendingCount)` alone misses a
    /// count that was nonzero *before* the observer existed (a cold launch whose
    /// scene restoration suppressed the Welcome window, for example).
    func drainViewAppeared(opener: @escaping (WorkspaceRef) -> Void) -> [WorkspaceRef] {
        drainObservers += 1
        windowOpener = opener
        return drain()
    }

    func drainViewDisappeared() {
        drainObservers = max(0, drainObservers - 1)
    }

    func enqueue(_ ref: WorkspaceRef, runAgent: Bool = false) {
        pending.append(ref)
        if runAgent {
            pendingAgentLaunches.insert(WorkspaceRef.canonical(ref.path))
            agentLaunchSignal &+= 1
        }
        // With every window closed the app keeps running but nothing observes
        // `pendingCount` — a Finder/CLI open would sit queued (and fire,
        // confusingly, minutes later when the user next opens a window). Open
        // it directly instead.
        if drainObservers == 0, let windowOpener {
            for queued in drain() { windowOpener(queued) }
        }
    }

    /// Returns and clears all queued workspaces.
    func drain() -> [WorkspaceRef] {
        let queued = pending
        pending.removeAll()
        return queued
    }

    /// Returns whether the given root was enqueued with an agent launch,
    /// consuming the request so it fires exactly once.
    func consumeAgentLaunch(for url: URL) -> Bool {
        pendingAgentLaunches.remove(WorkspaceRef.canonical(url.path(percentEncoded: false))) != nil
    }
}
