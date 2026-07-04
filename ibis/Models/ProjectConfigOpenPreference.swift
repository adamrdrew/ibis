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
    private static let defaults = UserDefaults.standard
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
