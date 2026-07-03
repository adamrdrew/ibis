import Foundation
import os

/// Persistent per-project MCP tokens. Each workspace root gets a stable token,
/// written into that project's agent config so requests carrying it route to
/// that project's window. Stored in UserDefaults as `[rootPath: token]`.
enum MCPTokenStore {
    private static let key = "mcp.projectTokens.v1"

    static func token(for root: URL) -> String {
        let path = root.standardizedFileURL.path(percentEncoded: false)
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let existing = map[path] { return existing }
        let token = AppSettings.freshToken()
        map[path] = token
        UserDefaults.standard.set(map, forKey: key)
        return token
    }
}

/// A thread-safe snapshot of the tokens the server should accept, readable from
/// the transport's synchronous, non-main `authorizationHandler`. Kept in sync by
/// `MCPBridge` (on the main actor) as windows open and close.
final class MCPTokenRegistry: @unchecked Sendable {
    static let shared = MCPTokenRegistry()
    private init() {}

    private let lock = OSAllocatedUnfairLock(initialState: Set<String>())

    func insert(_ token: String) {
        lock.withLock { $0.insert(token) }
    }

    func remove(_ token: String) {
        lock.withLock { _ = $0.remove(token) }
    }

    func contains(_ token: String) -> Bool {
        lock.withLock { $0.contains(token) }
    }
}
