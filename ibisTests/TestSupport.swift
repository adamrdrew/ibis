import Foundation

/// Shared helpers for the unit tests: throwaway temp directories and
/// snapshot/restore of `UserDefaults` keys so persistence tests don't leave
/// state behind on the developer's machine.
enum TestSupport {
    /// Creates a unique, empty temp directory. Caller is responsible for cleanup
    /// (use `withTempDir` to get automatic removal).
    static func makeTempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "ibisTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs `body` with a fresh temp directory, removing it afterward.
    static func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    /// Async variant of `withTempDir`.
    static func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    /// Snapshots a `UserDefaults` key, runs `body`, then restores the key's prior
    /// value (or removes it if it didn't exist), so persistence tests stay
    /// hermetic and can't pollute the standard suite.
    static func withPreservedDefault<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        let prior = UserDefaults.standard.object(forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        // Start from a clean slate so leftover state can't mask a bug.
        UserDefaults.standard.removeObject(forKey: key)
        return try body()
    }
}
