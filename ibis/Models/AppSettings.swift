import SwiftUI
import Observation

/// User-configurable editor and appearance settings, shared across all windows
/// through the environment and persisted to `UserDefaults`.
@Observable
final class AppSettings {
    var fontName: String { didSet { defaults.set(fontName, forKey: Key.fontName) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: Key.tabWidth) } }
    var usesSoftTabs: Bool { didSet { defaults.set(usesSoftTabs, forKey: Key.usesSoftTabs) } }
    var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: Key.showLineNumbers) } }
    var wordWrap: Bool { didSet { defaults.set(wordWrap, forKey: Key.wordWrap) } }

    // Not yet surfaced in the UI; kept for the editor configuration.
    var lineSpacing: Double = 2
    var showInvisibles: Bool = false
    var themeName: String = "System"

    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        // `didSet` doesn't fire for these initial assignments, so nothing is
        // written back during load.
        fontName = defaults.string(forKey: Key.fontName) ?? "SF Mono"
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? 13
        tabWidth = defaults.object(forKey: Key.tabWidth) as? Int ?? 4
        usesSoftTabs = defaults.object(forKey: Key.usesSoftTabs) as? Bool ?? true
        showLineNumbers = defaults.object(forKey: Key.showLineNumbers) as? Bool ?? true
        wordWrap = defaults.object(forKey: Key.wordWrap) as? Bool ?? false
    }

    private enum Key {
        static let fontName = "editor.fontName"
        static let fontSize = "editor.fontSize"
        static let tabWidth = "editor.tabWidth"
        static let usesSoftTabs = "editor.usesSoftTabs"
        static let showLineNumbers = "editor.showLineNumbers"
        static let wordWrap = "editor.wordWrap"
    }
}
