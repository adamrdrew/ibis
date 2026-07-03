import Foundation

/// A snapshot of a window's editor layout, persisted per workspace root so the
/// tabs, panes, and selection come back on relaunch.
struct PersistedWorkspaceState: Codable {
    /// One array of tab file paths per pane (untitled documents are omitted).
    var paneFilePaths: [[String]]
    /// Index into each pane's path array of the selected tab (-1 for none).
    var selectedTabPerPane: [Int]
    /// Index of the active pane.
    var activePaneIndex: Int
    /// When this snapshot was taken, for evicting the oldest roots.
    var savedAt: Date
}

/// UserDefaults-backed store of `PersistedWorkspaceState`, keyed by root path,
/// in a single dictionary capped to the most-recent roots.
enum WorkspaceStateStore {
    private static let key = "workspaceState.v1"
    private static let maxRoots = 20

    static func load(for root: URL) -> PersistedWorkspaceState? {
        guard let data = dictionary()[root.path(percentEncoded: false)] else { return nil }
        return try? JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
    }

    static func save(_ state: PersistedWorkspaceState, for root: URL) {
        guard let encoded = try? JSONEncoder().encode(state) else { return }
        var dict = dictionary()
        dict[root.path(percentEncoded: false)] = encoded
        evictIfNeeded(&dict)
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static func dictionary() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    }

    /// Keeps only the `maxRoots` most-recently-saved roots.
    private static func evictIfNeeded(_ dict: inout [String: Data]) {
        guard dict.count > maxRoots else { return }
        let decoder = JSONDecoder()
        let byDate = dict.sorted { lhs, rhs in
            let l = (try? decoder.decode(PersistedWorkspaceState.self, from: lhs.value))?.savedAt ?? .distantPast
            let r = (try? decoder.decode(PersistedWorkspaceState.self, from: rhs.value))?.savedAt ?? .distantPast
            return l > r
        }
        dict = Dictionary(uniqueKeysWithValues: byDate.prefix(maxRoots).map { ($0.key, $0.value) })
    }
}
