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

    /// Observable signal that a drain is needed. Views observe this in `onChange`.
    var pendingCount: Int { pending.count }

    private init() {}

    func enqueue(_ ref: WorkspaceRef) {
        pending.append(ref)
    }

    /// Returns and clears all queued workspaces.
    func drain() -> [WorkspaceRef] {
        let queued = pending
        pending.removeAll()
        return queued
    }
}
