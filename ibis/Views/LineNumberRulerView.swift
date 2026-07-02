import AppKit
import SwiftUI

/// A line-number gutter for the code editor, drawn as an `NSRulerView` attached
/// to the scroll view. Uses the TextKit 1 layout manager to align numbers with
/// each logical line (wrapped lines share a single number).
final class LineNumberRulerView: NSRulerView {
    private weak var editorTextView: NSTextView?

    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet { needsDisplay = true }
    }
    var textColor: NSColor = .tertiaryLabelColor

    /// The gutter fills itself with this so it blends with the editor and there
    /// is no seam between the numbers and the code. Matches the syntax theme's
    /// background.
    var backgroundColor: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
    }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.editorTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // macOS 26+: the scroll-edge "pocket" machinery calls this NSRulerView
    // hook to draw the ruler's trailing separator, and extends it *above* the
    // scroll view into the pane header band (the 1px line through the tab
    // bar). Ibis draws no gutter separator by design, so this is a no-op.
    // Override-only use of a private hook: if AppKit renames it, this method
    // simply stops being called and nothing breaks.
    @objc(drawSeparatorInRect:)
    private func drawSeparator(in rect: NSRect) {
        // Intentionally draw nothing.
    }

    // IMPORTANT: draw via `drawHashMarksAndLabels`, never by overriding
    // `draw(_:)`. Our line-number drawing forces TextKit layout (via the layout
    // manager), and doing that from `draw(_:)` corrupts the shared layout during
    // the display cycle — which blanks the text view and breaks pane rendering.
    // `drawHashMarksAndLabels` is the sanctioned hook where forcing layout is
    // safe.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        drawLineNumbers()
    }

    /// Resizes the gutter to fit the widest line number in the document.
    func updateThickness() {
        guard let textView = editorTextView else { return }
        let content = textView.string as NSString
        let lineCount = max(1, newlineCount(in: content, upTo: content.length) + 1)
        let digits = max(3, String(lineCount).count)
        let sample = String(repeating: "9", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: font]).width + 14
        let clamped = max(36, width)
        if abs(ruleThickness - clamped) > 0.5 {
            ruleThickness = clamped
        }
    }

    private func drawLineNumbers() {
        guard let textView = editorTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView else { return }

        let content = textView.string as NSString
        let inset = textView.textContainerInset.height
        let relativePoint = convert(NSZeroPoint, from: textView)

        let visibleRect = scrollView.contentView.bounds
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        guard visibleGlyphRange.length > 0 || content.length == 0 else {
            drawFirstLineNumberIfEmpty(content: content, relativeY: relativePoint.y, inset: inset)
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        let firstVisibleChar = layoutManager.characterIndexForGlyph(at: visibleGlyphRange.location)
        var lineNumber = newlineCount(in: content, upTo: firstVisibleChar) + 1

        var glyphIndex = visibleGlyphRange.location
        let maxGlyph = NSMaxRange(visibleGlyphRange)

        while glyphIndex < maxGlyph {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineCharRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)

            let fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: lineGlyphRange.location,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            drawNumber(lineNumber, atY: relativePoint.y + fragmentRect.minY + inset, height: fragmentRect.height, attributes: attributes)

            lineNumber += 1
            glyphIndex = max(NSMaxRange(lineGlyphRange), glyphIndex + 1)
        }

        // Trailing empty line (file ends with a newline).
        if layoutManager.extraLineFragmentTextContainer != nil {
            let fragmentRect = layoutManager.extraLineFragmentRect
            drawNumber(lineNumber, atY: relativePoint.y + fragmentRect.minY + inset, height: fragmentRect.height, attributes: attributes)
        }
    }

    // MARK: - Helpers

    private func drawFirstLineNumberIfEmpty(content: NSString, relativeY: CGFloat, inset: CGFloat) {
        guard content.length == 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        drawNumber(1, atY: relativeY + inset, height: font.boundingRectForFont.height, attributes: attributes)
    }

    private func drawNumber(_ number: Int, atY y: CGFloat, height: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attributes)
        let x = ruleThickness - size.width - 6
        let drawY = y + (height - size.height) / 2
        text.draw(at: NSPoint(x: x, y: drawY), withAttributes: attributes)
    }

    private func newlineCount(in string: NSString, upTo index: Int) -> Int {
        guard index > 0 else { return 0 }
        let length = min(index, string.length)
        var count = 0
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: length)
        defer { buffer.deallocate() }
        string.getCharacters(buffer, range: NSRange(location: 0, length: length))
        for i in 0..<length where buffer[i] == 10 {
            count += 1
        }
        return count
    }
}
