import Foundation

/// One persisted terminal tab: enough to recreate it on relaunch. The `.run`
/// project-action tab is never persisted.
struct PersistedTerminalSession: Codable {
    /// `.shell` for an interactive shell, `.agent` for a launched coding agent
    /// (encoded as the raw strings "shell"/"agent").
    var role: TerminalSession.Role
    /// The tab title at snapshot time (a fresh shell/agent may overwrite it).
    var title: String
    /// For a Claude agent, the session UUID to resume (`claude --resume <uuid>`).
    var agentSessionID: String?
}

/// A snapshot of the integrated terminal dock, persisted per workspace root.
struct PersistedTerminalDock: Codable {
    var sessions: [PersistedTerminalSession]
    /// Index into `sessions` of the active tab (-1 for none).
    var activeSessionIndex: Int
    var isVisible: Bool
    /// The dock's remembered size: `height` when docked at the bottom, `width`
    /// when trailing. Optional so payloads written before per-root dock sizing
    /// still decode (falling back to the dock's defaults).
    var height: Double? = nil
    var width: Double? = nil
}

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
    /// The terminal dock (shells + agents). Optional so payloads written before
    /// terminal persistence still decode (as `nil`).
    var terminal: PersistedTerminalDock? = nil
    /// Each pane's share of the editor width (sums to ~1, one entry per pane).
    /// Optional so older payloads still decode.
    var paneWidthFractions: [Double]? = nil
}

/// UserDefaults-backed store of `PersistedWorkspaceState`, keyed by root path,
/// in a single dictionary capped to the most-recent roots.
enum WorkspaceStateStore {
    private static let key = "workspaceState.v1"
    private static let maxRoots = 20

    static func load(for root: URL) -> PersistedWorkspaceState? {
        let dict = dictionary()
        // Fall back to the pre-normalization spelling: entries written before
        // keys were slash-stripped were keyed exactly as the URL was spelled,
        // which for Finder/`open`-launched folders carried a trailing slash.
        // Without this, updating the app would silently orphan those layouts.
        guard let data = dict[key(for: root)] ?? dict[key(for: root) + "/"] else { return nil }
        return try? JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
    }

    static func save(_ state: PersistedWorkspaceState, for root: URL) {
        guard let encoded = try? JSONEncoder().encode(state) else { return }
        var dict = dictionary()
        dict[key(for: root)] = encoded
        // Migrate away any legacy trailing-slash entry for the same folder, so
        // it doesn't linger as an orphan consuming one of the eviction slots.
        dict[key(for: root) + "/"] = nil
        evictIfNeeded(&dict)
        IbisDefaults.store.set(dict, forKey: key)
    }

    /// The dictionary key for a root: the path with trailing slashes stripped.
    /// Pure string normalization — the same folder opened with a trailing slash
    /// (Finder/`open`) or without (the CLI usually) must key to a single entry,
    /// but deliberately *not* `standardizedFileURL`/`resolvingSymlinksInPath`:
    /// those touch the filesystem and special-case `/tmp`→`/private/tmp`,
    /// resolving inconsistently for non-existent paths (which flaked the
    /// sandboxed test host).
    private static func key(for root: URL) -> String {
        root.path(percentEncoded: false).strippingTrailingSlashes
    }

    private static func dictionary() -> [String: Data] {
        IbisDefaults.store.dictionary(forKey: key) as? [String: Data] ?? [:]
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
