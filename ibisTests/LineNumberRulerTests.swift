import Testing
import AppKit
@testable import Ibis

/// Headless tests for the line-number gutter's width calculation. The gutter's
/// drawing needs a live window/layout pass and isn't testable here, but
/// `updateThickness` only measures the text, so it can run against detached
/// AppKit views.
@MainActor
@Suite struct LineNumberRulerTests {
    /// A detached scroll view + text view + ruler, no window required.
    private func makeEditor(text: String) -> (scrollView: NSScrollView, textView: NSTextView, ruler: LineNumberRulerView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.string = text
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = textView
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        return (scrollView, textView, ruler)
    }

    /// A programmatic content replacement that grows the file (external reload,
    /// applied agent edit) must widen the gutter for the extra digits — this is
    /// the resize the contentVersion-changed path in `CodeEditorView` relies on,
    /// since such replacements never fire `textDidChange`.
    @Test func thicknessGrowsWhenContentGainsDigits() {
        let editor = makeEditor(text: "one\ntwo\nthree")
        editor.ruler.updateThickness()
        let narrow = editor.ruler.ruleThickness

        // 12,000 lines → 5-digit line numbers.
        editor.textView.string = Array(repeating: "x", count: 12_000).joined(separator: "\n")
        editor.ruler.updateThickness()
        #expect(editor.ruler.ruleThickness > narrow)
    }

    @Test func thicknessShrinksBackWhenContentShrinks() {
        let editor = makeEditor(text: Array(repeating: "x", count: 12_000).joined(separator: "\n"))
        editor.ruler.updateThickness()
        let wide = editor.ruler.ruleThickness

        editor.textView.string = "just\na\nfew\nlines"
        editor.ruler.updateThickness()
        #expect(editor.ruler.ruleThickness < wide)
    }

    /// Everything up to 999 lines shares the 3-digit floor, so ordinary typing
    /// doesn't wobble the gutter width.
    @Test func smallFilesShareTheThreeDigitFloor() {
        let editor = makeEditor(text: "a")
        editor.ruler.updateThickness()
        let floor = editor.ruler.ruleThickness

        editor.textView.string = Array(repeating: "l", count: 999).joined(separator: "\n")
        editor.ruler.updateThickness()
        #expect(editor.ruler.ruleThickness == floor)
    }
}
