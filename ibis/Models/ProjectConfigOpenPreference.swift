import Foundation

/// How Ibis should handle a user opening a project's `.ibis.json`: ask each time,
/// always open the Project Settings editor, or always open the raw file.
enum IbisConfigOpenBehavior: String, CaseIterable, Identifiable {
    case ask
    case settings
    case text

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask: "Ask Each Time"
        case .settings: "Open Project Settings"
        case .text: "Open the Raw File"
        }
    }
}

/// Persists how `.ibis.json` opens: an app-wide default plus optional per-project
/// overrides (keyed by project root path), both in `UserDefaults`. Mirrors the
/// app's other lightweight stores (e.g. `WorkspaceStateStore`).
///
/// A per-project override is only ever `.settings` or `.text` — `.ask` means
/// "no override, follow the global default".
@MainActor
enum ProjectConfigOpenStore {
    private static var defaults: UserDefaults { IbisDefaults.store }
    private static let globalKey = "ibisConfig.openBehavior"
    private static let perProjectKey = "ibisConfig.perProject"

    /// The app-wide default, used when a project has no override of its own.
    static var globalDefault: IbisConfigOpenBehavior {
        get { defaults.string(forKey: globalKey).flatMap(IbisConfigOpenBehavior.init) ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: globalKey) }
    }

    /// The per-project override, if the user chose "remember for this project".
    static func preference(for root: URL) -> IbisConfigOpenBehavior? {
        guard let map = defaults.dictionary(forKey: perProjectKey) as? [String: String],
              let raw = map[key(for: root)] else { return nil }
        return IbisConfigOpenBehavior(rawValue: raw)
    }

    /// Records a per-project override so this project stops asking.
    static func setPreference(_ behavior: IbisConfigOpenBehavior, for root: URL) {
        var map = (defaults.dictionary(forKey: perProjectKey) as? [String: String]) ?? [:]
        map[key(for: root)] = behavior.rawValue
        defaults.set(map, forKey: perProjectKey)
    }

    /// The effective behavior for a project: its override, else the global default.
    static func effective(for root: URL) -> IbisConfigOpenBehavior {
        preference(for: root) ?? globalDefault
    }

    private static func key(for root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Remembers projects where the user declined the proactive offer to add Ibis to
/// an existing agent MCP config, so Ibis doesn't re-ask on every open. Accepting
/// needs no record — the Ibis entry is then present, so the offer never fires
/// again on its own. Keyed by project root path in `UserDefaults`.
@MainActor
enum MCPAdoptionStore {
    private static var defaults: UserDefaults { IbisDefaults.store }
    private static let declinedKey = "ibisMCP.declinedRoots"
    /// Separate list for the legacy-config *upgrade* offer: declining to add
    /// Ibis and declining to modernize an existing entry are distinct choices.
    private static let upgradeDeclinedKey = "ibisMCP.upgradeDeclinedRoots"

    static func hasDeclined(_ root: URL) -> Bool {
        (defaults.stringArray(forKey: declinedKey) ?? []).contains(key(for: root))
    }

    static func setDeclined(_ root: URL) {
        var list = defaults.stringArray(forKey: declinedKey) ?? []
        let k = key(for: root)
        guard !list.contains(k) else { return }
        list.append(k)
        defaults.set(list, forKey: declinedKey)
    }

    static func hasDeclinedUpgrade(_ root: URL) -> Bool {
        (defaults.stringArray(forKey: upgradeDeclinedKey) ?? []).contains(key(for: root))
    }

    static func setDeclinedUpgrade(_ root: URL) {
        var list = defaults.stringArray(forKey: upgradeDeclinedKey) ?? []
        let k = key(for: root)
        guard !list.contains(k) else { return }
        list.append(k)
        defaults.set(list, forKey: upgradeDeclinedKey)
    }

    private static func key(for root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
