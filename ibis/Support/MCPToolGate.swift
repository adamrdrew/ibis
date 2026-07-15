import os

/// A thread-safe snapshot of which optional MCP tools the server exposes,
/// readable from the server's nonisolated tool-listing and dispatch paths
/// (same pattern as `MCPTokenRegistry`). Kept in sync by `AppSettings` (on the
/// main actor) at load and whenever the setting changes, so toggling it applies
/// to the running server without a restart — agents pick it up on their next
/// tools/list fetch (in practice, their next session).
nonisolated enum MCPToolGate {
    private static let reviewToolState = OSAllocatedUnfairLock(initialState: false)

    /// Whether `propose_edit` / `propose_patch` (the human-review tools) are
    /// exposed to agents. Mirrors `AppSettings.mcpReviewToolEnabled`.
    static var reviewToolExposed: Bool {
        get { reviewToolState.withLock { $0 } }
        set { reviewToolState.withLock { $0 = newValue } }
    }
}
