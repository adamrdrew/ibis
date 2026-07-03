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

    /// Roots (by path) that should launch the configured agent once their
    /// window opens. Kept separate from `WorkspaceRef` so the window's
    /// restoration identity is unchanged and restored windows never re-run the
    /// agent. Consumed once by the opening workspace.
    private var pendingAgentLaunches: Set<String> = []

    /// Observable signal that a drain is needed. Views observe this in `onChange`.
    var pendingCount: Int { pending.count }

    private init() {}

    func enqueue(_ ref: WorkspaceRef, runAgent: Bool = false) {
        pending.append(ref)
        if runAgent { pendingAgentLaunches.insert(ref.path) }
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
        pendingAgentLaunches.remove(url.path(percentEncoded: false)) != nil
    }
}
