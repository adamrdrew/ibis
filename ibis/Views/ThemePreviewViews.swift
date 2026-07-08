import SwiftUI
import AppKit

// MARK: - Terminal theme preview

/// A static, non-interactive sample of a terminal color theme for the Settings
/// window: a few lines of colored shell output plus the 16-color ANSI swatch
/// strip. Pure SwiftUI — it doesn't spawn a PTY, so it's instant and cheap.
struct TerminalThemePreview: View {
    let theme: TerminalTheme
    let fontName: String
    let fontSize: Double

    private var font: Font {
        .custom(fontName, fixedSize: max(9, fontSize - 1))
    }

    private func color(_ index: Int) -> Color {
        guard theme.ansi.indices.contains(index) else { return foreground }
        return Color(nsColor: theme.ansi[index].nsColor)
    }

    private var foreground: Color { Color(nsColor: theme.foreground.nsColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                line([("user@ibis", color(2)), (":", foreground), ("~/project", color(4)),
                      ("$ ", foreground), ("git status", color(3))])
                line([("Modified files ready to commit", color(2))])
                line([("error: ", color(1)), ("nothing staged", foreground)])
                line([("~/project ", color(4)), ("main", color(5)),
                      (" ▍", Color(nsColor: theme.cursor.nsColor))])
            }
            .font(font)
            .lineLimit(1)

            swatches
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: theme.background.nsColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    /// Builds one line of differently-colored segments as a single `Text` via
    /// `AttributedString` (Text concatenation with `+` is deprecated on macOS 26).
    private func line(_ segments: [(String, Color)]) -> Text {
        var attributed = AttributedString()
        for (string, color) in segments {
            var run = AttributedString(string)
            run.foregroundColor = color
            attributed.append(run)
        }
        return Text(attributed)
    }

    private var swatches: some View {
        HStack(spacing: 3) {
            ForEach(Array(theme.ansi.enumerated()), id: \.offset) { _, swatch in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: swatch.nsColor))
                    .frame(height: 12)
            }
        }
    }
}

// MARK: - Editor theme preview

/// A static sample of source code rendered through the real syntax highlighter
/// for a given highlight.js theme name, so the Settings window shows exactly how
/// the editor will look. Highlighting runs on the shared actor, then a read-only
/// `NSTextView` paints the styled runs on the theme's background.
struct EditorThemePreview: View {
    let themeName: String
    let fontName: String
    let fontSize: Double

    @State private var result: HighlightResult?

    private static let language = "swift"
    private static let sample = """
        import Foundation

        /// Greets a person by name.
        struct Greeter {
            let name: String

            func greeting() -> String {
                return "Hello, \\(name)!"
            }
        }

        let count = 42
        print(Greeter(name: "Ibis").greeting())
        """

    var body: some View {
        CodeSampleView(sample: Self.sample, result: result, fontName: fontName, fontSize: fontSize)
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .task(id: "\(themeName)|\(fontName)|\(fontSize)") {
                result = await SyntaxHighlighter.shared.highlight(
                    code: Self.sample,
                    language: Self.language,
                    theme: themeName,
                    fontName: fontName,
                    fontSize: fontSize)
            }
    }
}

/// Read-only `NSTextView` that paints a highlighted sample. Highlighting is
/// awaited by the SwiftUI parent (`HighlightResult` is `Sendable`); this view
/// just composes the attributed string from the result and the constant sample.
private struct CodeSampleView: NSViewRepresentable {
    let sample: String
    let result: HighlightResult?
    let fontName: String
    let fontSize: Double

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let base = NSFont(name: fontName, size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attributed = NSMutableAttributedString(string: sample)
        let full = NSRange(location: 0, length: (sample as NSString).length)
        attributed.addAttribute(.font, value: base, range: full)
        attributed.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)

        for run in result?.runs ?? [] where NSMaxRange(run.range) <= attributed.length {
            attributed.addAttribute(.foregroundColor, value: run.color.nsColor, range: run.range)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if run.isBold { traits.insert(.bold) }
            if run.isItalic { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
                if let styled = NSFont(descriptor: descriptor, size: fontSize) {
                    attributed.addAttribute(.font, value: styled, range: run.range)
                }
            }
        }

        textView.textStorage?.setAttributedString(attributed)
        textView.backgroundColor = result?.background?.nsColor ?? .textBackgroundColor
    }
}
