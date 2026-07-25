import Testing
import Foundation
import AppKit
@testable import Ibis

/// The editor carries a token's colour onto characters typed into it, so a word
/// doesn't flash plain while it's being spelled out and only catch its colour
/// when the next highlight pass lands.
@MainActor
@Suite struct TypingColorContinuityTests {
    private let tokenColor = NSColor.systemPurple

    /// Builds a real editor stack around `text` and colours `coloredRange` as if
    /// a highlight pass had classified it.
    private func makeEditor(
        text: String,
        coloredRange: NSRange
    ) -> (CodeEditorView.Coordinator, NSTextView, NSTextStorage) {
        let document = OpenDocument()
        document.text = text
        let storage = document.storage

        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        storage.addAttribute(.foregroundColor, value: tokenColor, range: coloredRange)

        let coordinator = CodeEditorView.Coordinator(document: document)
        coordinator.textView = textView
        textView.delegate = coordinator
        return (coordinator, textView, storage)
    }

    /// Types `character` at `location` through the delegate, the way AppKit does.
    private func type(
        _ character: String,
        at location: Int,
        _ coordinator: CodeEditorView.Coordinator,
        _ textView: NSTextView
    ) {
        let range = NSRange(location: location, length: 0)
        _ = coordinator.textView(textView, shouldChangeTextIn: range, replacementString: character)
        textView.setSelectedRange(range)
        textView.insertText(character, replacementRange: range)
    }

    @Test func continuingAColouredWordKeepsItsColour() {
        // "let Foo" — "Foo" already classified.
        let (coordinator, textView, storage) = makeEditor(
            text: "let Foo", coloredRange: NSRange(location: 4, length: 3))

        type("o", at: 7, coordinator, textView)

        #expect(storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor == tokenColor)
    }

    /// The effect has to compound: the inherited colour is written into the
    /// character, so the next keystroke inherits from it and the whole word stays
    /// coloured without waiting for another pass.
    @Test func theInheritedColourCarriesAcrossFurtherKeystrokes() {
        let (coordinator, textView, storage) = makeEditor(
            text: "let F", coloredRange: NSRange(location: 4, length: 1))

        type("o", at: 5, coordinator, textView)
        type("o", at: 6, coordinator, textView)
        type("Bar", at: 7, coordinator, textView)

        for offset in 4..<storage.length {
            #expect(storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor == tokenColor,
                    "offset \(offset) should have kept the token colour")
        }
    }

    /// Inheriting across a space would make a new word wear the previous token's
    /// colour.
    @Test func aWordStartedAfterASpaceDoesNotInherit() {
        // "private " — the keyword is coloured, the trailing space is not.
        let (coordinator, textView, storage) = makeEditor(
            text: "private ", coloredRange: NSRange(location: 0, length: 7))

        type("s", at: 8, coordinator, textView)

        #expect(storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor == NSColor.textColor)
    }

    /// The case that makes naive inheritance actively wrong: a line typed under a
    /// comment must not come out comment-coloured.
    @Test func aLineTypedAfterACommentDoesNotInherit() {
        let text = "// a comment\n"
        let (coordinator, textView, storage) = makeEditor(
            text: text, coloredRange: NSRange(location: 0, length: (text as NSString).length))

        type("l", at: (text as NSString).length, coordinator, textView)

        let typed = (text as NSString).length
        #expect(storage.attribute(.foregroundColor, at: typed, effectiveRange: nil) as? NSColor == NSColor.textColor)
    }

    /// Punctuation ends a token, so it shouldn't carry the token's colour either.
    @Test func punctuationDoesNotInherit() {
        let (coordinator, textView, storage) = makeEditor(
            text: "let Foo", coloredRange: NSRange(location: 4, length: 3))

        type("(", at: 7, coordinator, textView)

        #expect(storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor == NSColor.textColor)
    }

    /// Typing at the very start of the buffer has no preceding character.
    @Test func insertingAtTheStartOfTheBufferIsPlain() {
        let (coordinator, textView, storage) = makeEditor(
            text: "Foo", coloredRange: NSRange(location: 0, length: 3))

        type("x", at: 0, coordinator, textView)

        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.textColor)
    }
}
