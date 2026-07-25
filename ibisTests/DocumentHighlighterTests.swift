import Testing
import Foundation
import AppKit
@testable import Ibis

/// An `NSTextStorage` that counts attribute writes, so the tests can assert on
/// the property the typing performance actually depends on: that a pass over
/// unchanged text touches *nothing*. Applying an attribute invalidates TextKit
/// layout across the range it touches even when the value is identical, so
/// "wrote the same value again" is not free — it is the whole cost.
@MainActor
final class CountingTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    nonisolated(unsafe) var attributeWrites = 0

    override nonisolated var string: String { backing.string }

    override nonisolated func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override nonisolated func replaceCharacters(in range: NSRange, with str: String) {
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
    }

    // `setAttributes(_:range:)` is the primitive every other attribute mutator
    // (including `addAttribute`) funnels through.
    override nonisolated func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        attributeWrites += 1
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }
}

@MainActor
@Suite struct DocumentHighlighterTests {
    /// ~60 KB of Swift, comfortably past the highlighter's 20 KB look-ahead so
    /// prefix limiting is observable.
    private func makeStorage(lines: Int) -> CountingTextStorage {
        let storage = CountingTextStorage()
        let source = String(repeating: "let value = 42 // a comment here\n", count: lines)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: source)
        return storage
    }

    private func makeHighlighter(_ storage: NSTextStorage) -> DocumentHighlighter {
        let highlighter = DocumentHighlighter(storage: storage)
        highlighter.language = "swift"
        return highlighter
    }

    @Test func appliesColorsToTheBuffer() async {
        let storage = makeStorage(lines: 20)
        let highlighter = makeHighlighter(storage)

        highlighter.refresh()
        await highlighter.awaitCurrentPass()

        // "let" is a keyword and must have been given a colour.
        let color = storage.attribute(.foregroundColor, at: 1, effectiveRange: nil)
        #expect(color != nil)
        #expect(highlighter.highlightedThrough == storage.length)
    }

    /// The core of the fix: re-running a pass over text that hasn't changed must
    /// not write a single attribute, because every write forces a relayout.
    @Test func repeatedPassOverUnchangedTextWritesNothing() async {
        let storage = makeStorage(lines: 20)
        let highlighter = makeHighlighter(storage)

        highlighter.refresh()
        await highlighter.awaitCurrentPass()
        #expect(storage.attributeWrites > 0, "the first pass must actually colour the buffer")

        storage.attributeWrites = 0
        highlighter.refresh()
        await highlighter.awaitCurrentPass()

        #expect(storage.attributeWrites == 0)
    }

    /// A pass parses only as far as the deepest viewport plus a look-ahead, so a
    /// long file is coloured where it's being read and left alone below.
    @Test func limitsParsingToTheViewportPrefix() async {
        let storage = makeStorage(lines: 2_000)   // ~64 KB
        let highlighter = makeHighlighter(storage)
        let pane = UUID()
        highlighter.attach(pane) { _ in }
        highlighter.reportViewport(pane, charEnd: 500)

        highlighter.refresh()
        await highlighter.awaitCurrentPass()

        #expect(highlighter.highlightedThrough < storage.length)
        #expect(storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) != nil)
        let deep = storage.length - 10
        #expect(storage.attribute(.foregroundColor, at: deep, effectiveRange: nil) == nil,
                "text far below the viewport should not have been parsed yet")
    }

    /// Scrolling past what's been coloured extends the parsed prefix.
    @Test func scrollingExtendsTheParsedPrefix() async {
        let storage = makeStorage(lines: 2_000)
        let highlighter = makeHighlighter(storage)
        let pane = UUID()
        highlighter.attach(pane) { _ in }
        highlighter.reportViewport(pane, charEnd: 500)
        highlighter.refresh()
        await highlighter.awaitCurrentPass()
        let firstReach = highlighter.highlightedThrough

        highlighter.reportViewport(pane, charEnd: firstReach + 1_000)
        await highlighter.awaitCurrentPass()

        #expect(highlighter.highlightedThrough > firstReach)
    }

    /// An unrecognised file type resets to plain text rather than keeping stale
    /// colours from a previous language.
    @Test func unknownLanguageFallsBackToPlainText() async {
        let storage = makeStorage(lines: 20)
        let highlighter = makeHighlighter(storage)
        highlighter.refresh()
        await highlighter.awaitCurrentPass()

        highlighter.language = nil
        highlighter.refresh()
        await highlighter.awaitCurrentPass()

        let color = storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.textColor)
    }

    /// Typing while a pass is parsing must not throw that pass away. An edit at
    /// offset F can't change the correct colouring before F, so the result still
    /// applies over `[0, F)` — without this, nothing is ever coloured *while*
    /// the user types, only during pauses long enough to fit a whole parse, and
    /// the highlighting visibly trails several words behind the caret.
    @Test func editDuringAPassStillAppliesTheValidPrefix() async {
        let storage = makeStorage(lines: 400)
        let highlighter = makeHighlighter(storage)
        let editPoint = storage.length

        highlighter.refresh()
        // Type at the very end while the parse is in flight.
        storage.replaceCharacters(in: NSRange(location: editPoint, length: 0), with: "struct S {}")
        await highlighter.awaitCurrentPass()

        // Everything before the edit was still coloured.
        #expect(storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) != nil)
        #expect(highlighter.highlightedThrough >= editPoint)
    }

    /// An edit mid-pass queues a follow-up rather than cancelling and
    /// restarting, so the text around the caret catches up on its own.
    @Test func aPassInterruptedByTypingSchedulesAFollowUp() async {
        let storage = makeStorage(lines: 400)
        let highlighter = makeHighlighter(storage)

        highlighter.refresh()
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "let tail = 1\n")
        await highlighter.awaitCurrentPass()
        // The follow-up pass runs after the first one lands.
        try? await Task.sleep(for: .milliseconds(600))
        await highlighter.awaitCurrentPass()

        #expect(highlighter.highlightedThrough == storage.length)
        let nearEnd = storage.length - 5
        #expect(storage.attribute(.foregroundColor, at: nearEnd, effectiveRange: nil) != nil,
                "the newly typed tail should be coloured once the follow-up pass lands")
    }

    /// Cancelling a request must stop it *inside* the actor, not merely discard
    /// its result — a burst of typing used to queue whole-document parses that
    /// each ran to completion before being thrown away.
    @Test func cancelledRequestsBailBeforeParsing() async {
        let task = Task {
            // Cancelled while suspended here, so `highlight` is entered with the
            // task already cancelled — no race.
            try? await Task.sleep(for: .seconds(10))
            return await SyntaxHighlighter.shared.highlight(
                code: "let x = 1",
                language: "swift",
                theme: EditorTheme.light,
                fontName: "Menlo",
                fontSize: 12
            )
        }
        task.cancel()
        #expect(await task.value == nil)
    }
}
