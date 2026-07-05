import Foundation
@testable import ibis

/// Shared helpers for the unit tests: throwaway temp directories and an isolated
/// `UserDefaults` so persistence tests never touch the developer's real
/// preferences.
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

    /// Runs `body` with every Ibis store (`WorkspaceStateStore`, `AppSettings`,
    /// `WorkspaceTrust`, `MCPTokenStore`, …) bound to a fresh, empty
    /// `UserDefaults` suite that is discarded afterward — so persistence tests
    /// can never read or mutate the developer's real preferences, no matter how
    /// the run ends. Isolation is via a task-local (`IbisDefaults.override`), so
    /// each test's suite is scoped to its own async call tree: no shared global,
    /// so no cross-suite races and no lock to deadlock on.
    static func withIsolatedDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let name = makeSuiteName()
        let suite = UserDefaults(suiteName: name)!
        defer { teardownSuite(suite, name) }
        return try await IbisDefaults.$override.withValue(DefaultsBox(suite)) {
            try await body()
        }
    }

    /// Synchronous variant of `withIsolatedDefaults`.
    static func withIsolatedDefaults<T>(_ body: () throws -> T) rethrows -> T {
        let name = makeSuiteName()
        let suite = UserDefaults(suiteName: name)!
        defer { teardownSuite(suite, name) }
        return try IbisDefaults.$override.withValue(DefaultsBox(suite), operation: body)
    }

    private static func makeSuiteName() -> String { "ibisTests-\(UUID().uuidString)" }

    /// Clears the suite and deletes its backing plist — `removePersistentDomain`
    /// alone leaves an empty file in ~/Library/Preferences, which would pile up
    /// one-per-test across runs.
    private static func teardownSuite(_ suite: UserDefaults, _ name: String) {
        suite.removePersistentDomain(forName: name)
        // Flush the emptied domain to disk before deleting the file, else
        // cfprefsd rewrites an empty plist back after our removal (they'd
        // otherwise accumulate one-per-test across runs).
        suite.synchronize()
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Preferences", name)
            .appendingPathExtension("plist")
        try? FileManager.default.removeItem(at: plist)
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
