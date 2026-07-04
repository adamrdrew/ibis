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
        try withPreservedDefaults([key], body)
    }

    /// Multi-key variant of `withPreservedDefault`.
    static func withPreservedDefaults<T>(_ keys: [String], _ body: () throws -> T) rethrows -> T {
        let priors = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, prior) in priors {
                if let prior { UserDefaults.standard.set(prior, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        // Start from a clean slate so leftover state can't mask a bug.
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        return try body()
    }

    /// Async variant of `withPreservedDefaults`, for suites that await while
    /// holding the preserved keys.
    static func withPreservedDefaults<T>(_ keys: [String], _ body: () async throws -> T) async rethrows -> T {
        let priors = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, prior) in priors {
                if let prior { UserDefaults.standard.set(prior, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        return try await body()
    }

    /// Polls `condition` on the main actor until it's true or `timeout` seconds
    /// elapse, yielding between checks so detached work (loads, searches, git
    /// probes) can land. Returns whether the condition became true.
    @MainActor
    static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
