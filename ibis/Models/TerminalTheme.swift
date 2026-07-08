import AppKit
import SwiftTerm

/// One color in a terminal theme, stored as sRGB components in 0...1 so it can
/// bridge to both AppKit (`NSColor`, for the native fg/bg/cursor/selection) and
/// SwiftTerm's own 16-bit `Color` (for the ANSI palette). Decodes from a
/// `"#rgb"` / `"#rrggbb"` hex string in the bundled catalog.
struct ThemeColor: Sendable, Hashable, Decodable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `"#rgb"` or `"#rrggbb"` (leading `#` optional). Returns nil on
    /// malformed input.
    init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        let characters = Array(string)

        func component(_ slice: [Character]) -> Double? {
            guard let value = UInt8(String(slice), radix: 16) else { return nil }
            return Double(value) / 255.0
        }

        switch characters.count {
        case 3:
            guard let r = component([characters[0], characters[0]]),
                  let g = component([characters[1], characters[1]]),
                  let b = component([characters[2], characters[2]]) else { return nil }
            red = r; green = g; blue = b
        case 6:
            guard let r = component(Array(characters[0..<2])),
                  let g = component(Array(characters[2..<4])),
                  let b = component(Array(characters[4..<6])) else { return nil }
            red = r; green = g; blue = b
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let parsed = ThemeColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid hex color \"\(hex)\"")
        }
        self = parsed
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// SwiftTerm's palette `Color` (0...65535 per channel). Uses the public
    /// 16-bit initializer since the 8-bit one is module-internal.
    var swiftTermColor: SwiftTerm.Color {
        func scaled(_ value: Double) -> UInt16 {
            UInt16((max(0, min(1, value)) * 65535).rounded())
        }
        return SwiftTerm.Color(red: scaled(red), green: scaled(green), blue: scaled(blue))
    }
}

/// A terminal color scheme: window background/foreground, cursor, selection, and
/// the 16 ANSI colors. `isDark` classifies it for the light/dark picker pair, so
/// the integrated terminal can follow the system appearance the way the editor
/// syntax theme does.
struct TerminalTheme: Identifiable, Hashable, Sendable, Decodable {
    let name: String
    let isDark: Bool
    let background: ThemeColor
    let foreground: ThemeColor
    let cursor: ThemeColor
    /// Text color under a block cursor; nil renders it with the background.
    let cursorText: ThemeColor?
    let selection: ThemeColor
    /// Exactly 16 entries (8 normal + 8 bright ANSI colors).
    let ansi: [ThemeColor]

    var id: String { name }

    /// Whether this theme is structurally usable by SwiftTerm's `installColors`.
    var hasValidPalette: Bool { ansi.count == 16 }
}

/// Loads and vends the bundled terminal themes. Parsing is factored out of the
/// bundle lookup (`decode(from:)`) so it can be unit-tested with inline JSON,
/// and there are always-available hardcoded fallbacks so a missing catalog or a
/// stale stored theme name can never leave the terminal unthemed.
enum TerminalThemeCatalog {
    /// SwiftTerm's Terminal.app palette — the look Ibis shipped before themes.
    static let fallbackDark = TerminalTheme(
        name: "Ibis Dark",
        isDark: true,
        background: hex("1e1e1e"),
        foreground: hex("cbcccd"),
        cursor: hex("cbcccd"),
        cursorText: hex("1e1e1e"),
        selection: hex("3a5f8a"),
        ansi: [
            hex("000000"), hex("c23621"), hex("25bc24"), hex("adad27"),
            hex("492ee1"), hex("d338d3"), hex("33bbc8"), hex("cbcccd"),
            hex("818383"), hex("fc391f"), hex("31e722"), hex("eaec23"),
            hex("5833ff"), hex("f935f8"), hex("14f0f0"), hex("e9ebeb"),
        ])

    static let fallbackLight = TerminalTheme(
        name: "Ibis Light",
        isDark: false,
        background: hex("ffffff"),
        foreground: hex("1f2023"),
        cursor: hex("1f2023"),
        cursorText: hex("ffffff"),
        selection: hex("b3d7ff"),
        ansi: [
            hex("000000"), hex("c23621"), hex("25a324"), hex("8a7d00"),
            hex("2649c1"), hex("b52bb5"), hex("0f8fa0"), hex("5f5f5f"),
            hex("818383"), hex("d13a1f"), hex("2eaa22"), hex("a89a00"),
            hex("3355ff"), hex("d23ad2"), hex("14b0c0"), hex("1f2023"),
        ])

    /// The parsed catalog: the bundled themes, or the two fallbacks if the
    /// resource is missing or unparseable.
    static let all: [TerminalTheme] = loadBundled()

    static var light: [TerminalTheme] { all.filter { !$0.isDark } }
    static var dark: [TerminalTheme] { all.filter { $0.isDark } }

    /// Parses a `TerminalThemes.json` payload. Keeps only entries with a full
    /// 16-color palette so a malformed theme can't reach `installColors`.
    static func decode(from data: Data) throws -> [TerminalTheme] {
        try JSONDecoder().decode([TerminalTheme].self, from: data)
            .filter(\.hasValidPalette)
    }

    /// Resolves a stored theme name, falling back to the first theme of the
    /// requested appearance (then a hardcoded default) when it no longer exists.
    static func theme(named name: String, isDark: Bool) -> TerminalTheme {
        if let match = all.first(where: { $0.name == name }) { return match }
        if isDark { return dark.first ?? fallbackDark }
        return light.first ?? fallbackLight
    }

    private static func loadBundled() -> [TerminalTheme] {
        guard let url = Bundle.main.url(forResource: "TerminalThemes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let themes = try? decode(from: data),
              !themes.isEmpty
        else {
            return [fallbackLight, fallbackDark]
        }
        return themes
    }

    /// Compile-time hex literal for the fallbacks; malformed input degrades to
    /// black rather than trapping.
    private static func hex(_ value: String) -> ThemeColor {
        ThemeColor(hex: value) ?? ThemeColor(red: 0, green: 0, blue: 0)
    }
}
