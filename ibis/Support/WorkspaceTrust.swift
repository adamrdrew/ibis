import Foundation

/// Per-folder trust decisions, VS Code-style. Opening a folder shouldn't let it
/// silently execute code from its own `.ibis.json` (environment injected into
/// every shell, named actions run verbatim). A folder must be *trusted* before
/// Ibis applies its project environment or exposes its actions.
///
/// Decisions persist in UserDefaults keyed by the canonical root path, so the
/// prompt appears once per folder.
enum WorkspaceTrust {
    private static let key = "workspace.trust.v1"

    /// Whether the user has explicitly trusted this folder.
    static func isTrusted(_ root: URL) -> Bool {
        map()[canonicalPath(root)] == true
    }

    /// Whether the user has made *any* decision about this folder yet (so we
    /// don't re-prompt after they chose "Don't Trust").
    static func hasDecision(_ root: URL) -> Bool {
        map()[canonicalPath(root)] != nil
    }

    /// Records the user's trust decision for a folder.
    static func setTrusted(_ trusted: Bool, for root: URL) {
        var current = map()
        current[canonicalPath(root)] = trusted
        IbisDefaults.store.set(current, forKey: key)
    }

    private static func map() -> [String: Bool] {
        IbisDefaults.store.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    /// A stable key for a root: symlinks resolved, no trailing slash — so a
    /// folder maps to one decision however its path was expressed.
    private static func canonicalPath(_ root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false).strippingTrailingSlashes
    }
}
