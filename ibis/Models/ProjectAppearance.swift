import SwiftUI
import AppKit

/// A project's optional appearance overrides, stored in `.ibis.json` under
/// `"appearance"`. Every field is optional and independent: a project can
/// override the dark editor theme alone and still inherit the light editor
/// theme, both terminal themes, and the accent from the app-wide settings.
struct ProjectAppearance: Equatable, Sendable {
    var editorLightTheme: String?
    var editorDarkTheme: String?
    var terminalLightTheme: String?
    var terminalDarkTheme: String?
    /// Accent color for this project's window only, replacing the app/system
    /// accent everywhere Ibis tints its own chrome.
    var accent: ThemeColor?

    static let none = ProjectAppearance()

    var isEmpty: Bool { self == .none }
}

// MARK: - `.ibis.json` shape
//
// Declared in an extension so the memberwise initializer survives.
extension ProjectAppearance {
    /// The on-disk key names, shared by the loader and the writer.
    enum Key {
        static let section = "appearance"
        static let editorLightTheme = "editorLightTheme"
        static let editorDarkTheme = "editorDarkTheme"
        static let terminalLightTheme = "terminalLightTheme"
        static let terminalDarkTheme = "terminalDarkTheme"
        static let accent = "accentColor"
    }

    /// Reads the `"appearance"` object out of a parsed `.ibis.json`. Unknown or
    /// malformed values are dropped (they fall through to the app defaults)
    /// rather than failing the whole config: a hand-edited theme name that no
    /// longer exists must not make the file unloadable.
    init(json: [String: Any]?) {
        guard let json else { return }
        func string(_ key: String) -> String? {
            guard let value = json[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        editorLightTheme = string(Key.editorLightTheme)
        editorDarkTheme = string(Key.editorDarkTheme)
        terminalLightTheme = string(Key.terminalLightTheme)
        terminalDarkTheme = string(Key.terminalDarkTheme)
        accent = string(Key.accent).flatMap(ThemeColor.init(hex:))
    }

    /// The JSON object to write back, or nil when nothing is overridden (so the
    /// key is removed rather than left as an empty object).
    var jsonObject: [String: Any]? {
        var object: [String: Any] = [:]
        object[Key.editorLightTheme] = editorLightTheme
        object[Key.editorDarkTheme] = editorDarkTheme
        object[Key.terminalLightTheme] = terminalLightTheme
        object[Key.terminalDarkTheme] = terminalDarkTheme
        object[Key.accent] = accent?.hexString
        return object.isEmpty ? nil : object
    }
}

/// The appearance a window actually renders with: the app-wide settings after a
/// project's overrides have been laid over them. Resolution is a pure function
/// of the two inputs, so the fall-through rules are unit-testable without a
/// window.
struct EffectiveAppearance: Equatable, Sendable {
    var editorLightTheme: String
    var editorDarkTheme: String
    var terminalLightTheme: String
    var terminalDarkTheme: String
    /// nil means "follow the app/system accent" — the normal case.
    var accent: ThemeColor?

    /// What a window shows with neither app settings nor project overrides
    /// (the shipped defaults, mirroring `AppSettings`' own initial values).
    static let appDefault = EffectiveAppearance(
        editorLightTheme: EditorTheme.light,
        editorDarkTheme: EditorTheme.dark,
        terminalLightTheme: TerminalThemeCatalog.fallbackLight.name,
        terminalDarkTheme: TerminalThemeCatalog.fallbackDark.name,
        accent: nil)

    /// Lays a project's overrides over the app-wide defaults, field by field.
    static func resolve(project: ProjectAppearance, defaults: EffectiveAppearance) -> EffectiveAppearance {
        EffectiveAppearance(
            editorLightTheme: project.editorLightTheme ?? defaults.editorLightTheme,
            editorDarkTheme: project.editorDarkTheme ?? defaults.editorDarkTheme,
            terminalLightTheme: project.terminalLightTheme ?? defaults.terminalLightTheme,
            terminalDarkTheme: project.terminalDarkTheme ?? defaults.terminalDarkTheme,
            accent: project.accent ?? defaults.accent)
    }

    /// The terminal theme for the current appearance, resolved through the
    /// catalog (which falls back when a stored name no longer exists).
    func terminalTheme(isDark: Bool) -> TerminalTheme {
        TerminalThemeCatalog.theme(
            named: isDark ? terminalDarkTheme : terminalLightTheme, isDark: isDark)
    }

    /// SwiftUI accent for this window: the project's override, else the app's.
    var accentColor: Color {
        accent.map { Color(nsColor: $0.nsColor) } ?? .ibisAccent
    }

    /// AppKit twin of ``accentColor``, for the views that cache an `NSColor`
    /// (the caret, the file browser's folder icons).
    var accentNSColor: NSColor {
        accent?.nsColor ?? .ibisAccent
    }
}

extension EnvironmentValues {
    /// The accent color of the enclosing window: a project's override when it
    /// has one, otherwise the app/system accent. Views inside a workspace read
    /// this instead of ``Color/ibisAccent`` so a project-scoped accent reaches
    /// them; views outside one (Welcome, Settings) get the app accent by
    /// default.
    @Entry var ibisAccent: Color = .accentColor
}
