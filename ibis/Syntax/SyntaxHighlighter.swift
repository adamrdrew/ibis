import AppKit
import Highlighter

/// A `Sendable` color (sRGB components) so highlight results can cross the actor
/// boundary without carrying non-`Sendable` `NSColor`s.
struct RGBAColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// One styled range produced by highlighting.
struct ColorRun: Sendable {
    let range: NSRange
    let color: RGBAColor
    let isBold: Bool
    let isItalic: Bool
}

/// The result of highlighting a document: styled runs plus the theme's
/// background so the editor can match it.
struct HighlightResult: Sendable {
    let runs: [ColorRun]
    let background: RGBAColor?
    let sourceLength: Int
}

/// Names of the light / dark highlight.js themes Ibis uses. Chosen to sit
/// comfortably alongside the app's restrained aesthetic and to track the system
/// appearance.
enum EditorTheme {
    static let light = "atom-one-light"
    static let dark = "atom-one-dark"

    static func name(isDark: Bool) -> String {
        isDark ? dark : light
    }
}

/// Serializes access to a single highlight.js-backed `Highlighter` (which makes
/// no thread-safety guarantees) and returns `Sendable` results.
actor SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    private var highlighter: Highlighter?
    private var loadedTheme: String?

    func highlight(
        code: String,
        language: String,
        theme: String,
        fontName: String,
        fontSize: Double
    ) -> HighlightResult? {
        if highlighter == nil {
            highlighter = Highlighter()
        }
        guard let highlighter else { return nil }

        if loadedTheme != theme {
            _ = highlighter.setTheme(theme)
            loadedTheme = theme
        }

        let font = NSFont(name: fontName, size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        highlighter.theme.setCodeFont(font)

        guard let attributed = highlighter.highlight(code, as: language, doFastRender: true) else {
            return nil
        }

        var runs: [ColorRun] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attributes, range, _ in
            let color = (attributes[.foregroundColor] as? NSColor) ?? .textColor
            var isBold = false
            var isItalic = false
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                isBold = traits.contains(.bold)
                isItalic = traits.contains(.italic)
            }
            runs.append(ColorRun(range: range, color: color.rgbaComponents, isBold: isBold, isItalic: isItalic))
        }

        let background = highlighter.theme.themeBackgroundColour?.rgbaComponents
        return HighlightResult(runs: runs, background: background, sourceLength: (code as NSString).length)
    }
}

extension NSColor {
    /// sRGB components, falling back gracefully for colors that can't convert.
    var rgbaComponents: RGBAColor {
        let converted = usingColorSpace(.sRGB) ?? self
        return RGBAColor(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
    }
}
