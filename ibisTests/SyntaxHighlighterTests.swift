import Testing
import Foundation
@testable import Ibis

@Suite struct SyntaxHighlighterTests {
    @Test func highlightingSwiftProducesStyledRuns() async {
        let result = await SyntaxHighlighter.shared.highlight(
            code: "let x = 42 // comment",
            language: "swift",
            theme: EditorTheme.light,
            fontName: "Menlo",
            fontSize: 12
        )
        let unwrapped = try? #require(result)
        #expect(unwrapped?.sourceLength == 21)
        // More than one run means the keyword/number/comment got distinct styles.
        #expect((unwrapped?.runs.count ?? 0) > 1)
        // Runs stay within the source bounds.
        let maxEnd = unwrapped?.runs.map { NSMaxRange($0.range) }.max() ?? 0
        #expect(maxEnd <= 21)
    }

    @Test func themeProvidesABackgroundColor() async {
        let result = await SyntaxHighlighter.shared.highlight(
            code: "print(1)",
            language: "swift",
            theme: EditorTheme.dark,
            fontName: "Menlo",
            fontSize: 12
        )
        #expect(result?.background != nil)
    }

    @Test func switchingThemesStillHighlights() async {
        let light = await SyntaxHighlighter.shared.highlight(
            code: "def f():\n    return 1",
            language: "python",
            theme: EditorTheme.light,
            fontName: "Menlo",
            fontSize: 12
        )
        let dark = await SyntaxHighlighter.shared.highlight(
            code: "def f():\n    return 1",
            language: "python",
            theme: EditorTheme.dark,
            fontName: "Menlo",
            fontSize: 12
        )
        #expect(light != nil)
        #expect(dark != nil)
    }

    @Test func availableThemesIncludeTheDefaults() async {
        let themes = await SyntaxHighlighter.shared.availableThemes()
        #expect(themes.contains(EditorTheme.light))
        #expect(themes.contains(EditorTheme.dark))
        // Sorted, per the API contract.
        #expect(themes == themes.sorted())
    }
}
