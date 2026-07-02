import SwiftUI
import Observation

/// User-configurable editor and appearance settings, shared across all windows
/// through the environment. Persistence via `UserDefaults` is wired up in a
/// later phase; for now these are in-memory defaults.
@Observable
final class AppSettings {
    var fontName: String = "SF Mono"
    var fontSize: Double = 13
    var lineSpacing: Double = 2
    var tabWidth: Int = 4
    var usesSoftTabs: Bool = true
    var showLineNumbers: Bool = true
    var wordWrap: Bool = false
    var showInvisibles: Bool = false
    var themeName: String = "System"
}
