import Foundation
import os

/// Persistent per-project MCP tokens. Each workspace root gets a stable token,
/// written into that project's agent config so requests carrying it route to
/// that project's window. Stored in UserDefaults as `[rootPath: token]`.
enum MCPTokenStore {
    private static let key = "mcp.projectTokens.v1"

    static func token(for root: URL) -> String {
        let path = canonicalPath(root)
        var map = IbisDefaults.store.dictionary(forKey: key) as? [String: String] ?? [:]
        if let existing = map[path] { return existing }
        let token = AppSettings.freshToken()
        map[path] = token
        IbisDefaults.store.set(map, forKey: key)
        return token
    }

    /// A stable key for a root: symlinks resolved (so `/tmp` and `/private/tmp`
    /// agree) and no trailing slash, so a folder maps to one token however its
    /// path was expressed.
    private static func canonicalPath(_ root: URL) -> String {
        var path = root.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// A thread-safe snapshot of the tokens the server should accept, readable from
/// the transport's synchronous, non-main `authorizationHandler`. Kept in sync by
/// `MCPBridge` (on the main actor) as windows open and close.
nonisolated final class MCPTokenRegistry: @unchecked Sendable {
    static let shared = MCPTokenRegistry()
    private init() {}

    private let lock = OSAllocatedUnfairLock(initialState: Set<String>())

    func insert(_ token: String) {
        lock.withLock { _ = $0.insert(token) }
    }

    func remove(_ token: String) {
        lock.withLock { _ = $0.remove(token) }
    }

    func contains(_ token: String) -> Bool {
        lock.withLock { $0.contains(token) }
    }
}
