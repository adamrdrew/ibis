import SwiftUI
import AppKit

/// Value-typed snapshot of the editor-affecting settings. Being `Equatable`
/// lets the representable cheaply decide when to reconfigure the text view.
struct EditorConfiguration: Equatable {
    var fontName: String
    var fontSize: Double
    var tabWidth: Int
    var usesSoftTabs: Bool
    var wordWrap: Bool
    var showLineNumbers: Bool
    var showInvisibles: Bool
    var lightTheme: String
    var darkTheme: String
}

/// The code editor: an `NSTextView` (TextKit 1 stack, for a line-number ruler
/// and direct `NSTextStorage` access that syntax highlighting will use later)
/// inside an `NSScrollView`, bridged to SwiftUI.
struct CodeEditorView: NSViewRepresentable {
    @Bindable var document: OpenDocument
    var configuration: EditorConfiguration
    /// Called when the editor becomes first responder, so the owning pane can
    /// mark itself active.
    var onActivate: () -> Void = {}
    /// A monotonically increasing token from the owning pane; when it changes,
    /// the editor takes keyboard focus (so Focus Next/Previous Editor works).
    var focusRequest: Int = 0
    /// Display name of the configured agent, for the "Send to <agent>" menu item.
    var agentName: String = "Agent"
    /// Delivers the editor's current text selection to the agent.
    var onSendToAgent: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Build an explicit TextKit 1 stack, attaching *this pane's* layout
        // manager to the document's shared storage so multiple panes editing the
        // same file share one buffer (see OpenDocument.storage).
        let textStorage = document.storage
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = EditorTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateHandler()
        }
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.appearanceChanged()
        }
        textView.onSendToAgent = onSendToAgent
        textView.agentName = agentName
        textView.isEditable = document.isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.insertionPointColor = .ibisAccent
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Canonical resizable text-view setup so it lays out (and is clickable /
        // focusable) once the enclosing scroll view is sized by SwiftUI.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.hasVerticalRuler = true

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.observeScrolling(in: scrollView)
        context.coordinator.observeAccentChanges()
        // Register this pane with the document's highlighter, which owns the
        // colouring of the shared buffer for every pane showing this file.
        context.coordinator.attachHighlighter()

        // The shared storage already holds the text; no need to assign a string.
        configure(textView, in: scrollView, ruler: ruler)
        syncCoordinator(context.coordinator)
        context.coordinator.lastContentVersion = document.contentVersion
        // Seed the focus token with the pane's *current* value: the token is
        // monotonic and never resets, while this coordinator is fresh per tab
        // mount (`.id(document.id)`) — starting at 0 would make every newly
        // mounted editor see a "new" token and steal first responder (e.g.
        // yanking keyboard focus out of the terminal when an agent opens a tab).
        context.coordinator.lastFocusRequest = focusRequest
        // Redraw the gutter on *storage-level* edits too, so a sibling pane
        // sharing this buffer updates its line numbers without its own
        // textDidChange (which only fires in the pane where the edit happened).
        context.coordinator.observeStorage(textStorage)

        // Position the viewport now, synchronously — never from the async
        // highlight completion, which on large files lands after the user has
        // started scrolling and would yank them back to the top.
        if document.isLoaded {
            context.coordinator.hasScrolledToStart = true
            if document.pendingSelection == nil {
                context.coordinator.restoreViewportAfterMount()
            }
        } else {
            // Content arrives via the first contentVersion bump (async load);
            // updateNSView scrolls to the start at that moment.
            context.coordinator.hasScrolledToStart = false
        }
        // Tell the highlighter what this pane can see before the first pass, so
        // it parses far enough to cover the viewport rather than only its floor.
        context.coordinator.reportViewport()
        document.highlighter.refresh()

        return scrollView
    }

    /// Detaches this pane's layout manager from the shared storage when the pane
    /// goes away, so closing/reopening panes doesn't accumulate layout managers
    /// (and redundant highlight passes) on a long-lived document buffer.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.saveSelectionForRemount()
        coordinator.detachFromStorage()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView,
              let ruler = context.coordinator.ruler else { return }

        if let editorTextView = textView as? EditorTextView {
            editorTextView.onSendToAgent = onSendToAgent
            editorTextView.agentName = agentName
        }

        var needsHighlight = false
        // The buffer is shared, so a *programmatic* replacement (load, revert,
        // applied agent edit) is already reflected here; we only need to
        // re-highlight, reset scroll, and drop stale undo actions (whose ranges
        // now point past the new, possibly shorter, backing store — undoing them
        // would throw an out-of-bounds exception).
        if context.coordinator.lastContentVersion != document.contentVersion {
            context.coordinator.lastContentVersion = document.contentVersion
            needsHighlight = true
            // First content arrival for a freshly opened (still-loading) editor:
            // position at the document start now, synchronously. Established
            // editors keep their scroll position across an external reload or
            // applied agent edit instead of being yanked to the top.
            context.coordinator.scrollToStartIfNeeded()
            // A programmatic replacement doesn't fire textDidChange, so resize
            // the gutter here — a file that grows externally (say 900 → 12,000
            // lines) would otherwise draw its line numbers clipped.
            ruler.updateThickness()
            ruler.needsDisplay = true
            // Clear only *this document's* undo stack. Because the text view uses
            // the document-scoped undo manager (see undoManager(for:)), this can't
            // wipe another file's history shown in a sibling pane.
            document.undoManager.removeAllActions()
        }

        let configChanged = context.coordinator.lastConfiguration != configuration
        if configChanged { needsHighlight = true }

        // The URL can change under a stable document (Save As of an untitled
        // buffer), which may change the language — refresh it.
        if context.coordinator.language != Language.highlightName(for: document.url) {
            needsHighlight = true
        }

        textView.isEditable = document.isEditable

        // Only reconfigure on an actual configuration change: `configure` sets the
        // font across the whole storage, which would wipe the highlighter's
        // bold/italic runs on every unrelated update (e.g. the dirty-flag flip).
        if configChanged || context.coordinator.lastConfiguration == nil {
            configure(textView, in: scrollView, ruler: ruler)
        }
        syncCoordinator(context.coordinator)

        // Typing never lands here: the highlighter watches the shared storage
        // itself, so this is only the out-of-band triggers (font/theme change,
        // a new language after Save As, a programmatic content replacement).
        if needsHighlight {
            document.highlighter.refresh()
        }

        applyPendingSelectionIfNeeded(context.coordinator)
        applyFocusRequestIfNeeded(textView, coordinator: context.coordinator)
    }

    /// Takes keyboard focus when the pane's focus token advances.
    private func applyFocusRequestIfNeeded(_ textView: NSTextView, coordinator: Coordinator) {
        guard focusRequest != 0, focusRequest != coordinator.lastFocusRequest else { return }
        coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// If the document requested a selection (e.g. opened from search), select
    /// and reveal it, then focus the editor. The observed `pendingSelection` flag
    /// is cleared inside the async block (never synchronously during the update
    /// pass) to avoid the "modifying state during view update" re-entrancy cycle.
    private func applyPendingSelectionIfNeeded(_ coordinator: Coordinator) {
        guard let textView = coordinator.textView,
              let pending = document.pendingSelection,
              !coordinator.pendingSelectionScheduled else { return }
        coordinator.pendingSelectionScheduled = true

        DispatchQueue.main.async { [weak document] in
            coordinator.pendingSelectionScheduled = false
            document?.pendingSelection = nil

            let length = (textView.string as NSString).length
            let location = min(pending.location, length)
            let clampedLength = min(pending.length, length - location)
            let range = NSRange(location: location, length: clampedLength)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// Pushes the current representable values the coordinator needs, and the
    /// styling inputs through to the document-level highlighter.
    private func syncCoordinator(_ coordinator: Coordinator) {
        coordinator.softTabsEnabled = configuration.usesSoftTabs
        coordinator.tabWidth = configuration.tabWidth
        coordinator.activateHandler = onActivate
        coordinator.lastConfiguration = configuration

        let highlighter = document.highlighter
        highlighter.language = Language.highlightName(for: document.url)
        highlighter.baseFont = makeFont()
        highlighter.fontName = configuration.fontName
        highlighter.fontSize = configuration.fontSize
        highlighter.lightThemeName = configuration.lightTheme
        highlighter.darkThemeName = configuration.darkTheme
        coordinator.syncAppearance()
    }

    // MARK: - Configuration

    private func makeFont() -> NSFont {
        if let font = NSFont(name: configuration.fontName, size: configuration.fontSize) {
            return font
        }
        return .monospacedSystemFont(ofSize: configuration.fontSize, weight: .regular)
    }

    private func configure(_ textView: NSTextView, in scrollView: NSScrollView, ruler: LineNumberRulerView) {
        let font = makeFont()

        let paragraph = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = spaceWidth * CGFloat(max(1, configuration.tabWidth))
        paragraph.tabStops = []

        textView.font = font
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph
        ]

        // Apply the paragraph style (tab width) across the document. Font and
        // foreground color are owned by the highlighter, so we deliberately
        // don't touch them here — otherwise a reconfigure (e.g. opening a search
        // result in an already-open file) would wipe the syntax colors.
        if let storage = textView.textStorage, storage.length > 0 {
            let full = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: full)
        }

        // Word wrap vs horizontal scrolling.
        if configuration.wordWrap {
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if let width = textView.enclosingScrollView?.contentSize.width {
                textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }
            scrollView.hasHorizontalScroller = false
        } else {
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }

        // Line numbers.
        scrollView.rulersVisible = configuration.showLineNumbers
        ruler.font = NSFont.monospacedDigitSystemFont(
            ofSize: max(9, configuration.fontSize - 2),
            weight: .regular
        )
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: OpenDocument
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        private var boundsObserver: NSObjectProtocol?
        private var accentObserver: NSObjectProtocol?
        private var storageObserver: NSObjectProtocol?
        /// Coalesces storage-edit gutter refreshes to one per runloop turn.
        private var gutterRefreshScheduled = false

        init(document: OpenDocument) {
            self.document = document
        }

        /// The insertion-point color is a cached `NSColor`, so re-apply it when
        /// the user changes the system accent so the caret follows live.
        func observeAccentChanges() {
            accentObserver = NotificationCenter.default.addObserver(
                forName: NSColor.systemColorsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.textView?.insertionPointColor = .ibisAccent
                }
            }
        }

        func observeScrolling(in scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.ruler?.needsDisplay = true
                    // Scrolling can reveal text past what the highlighter has
                    // parsed. Reporting is cheap and self-throttling: the
                    // highlighter only schedules work once the viewport runs
                    // past its look-ahead margin.
                    self?.reportViewport()
                }
            }
        }

        // MARK: - Syntax highlighting
        //
        // The work itself lives on `document.highlighter` (one highlighter per
        // document, not per pane). This pane's job is to say who it is, what it
        // can see, and to wear the theme's background colour.

        /// Identifies this pane to the document's highlighter.
        let highlighterClientID = UUID()

        func attachHighlighter() {
            document.highlighter.attach(highlighterClientID) { [weak self] background in
                guard let self else { return }
                let color = background?.nsColor ?? .textBackgroundColor
                self.textView?.backgroundColor = color
                self.textView?.insertionPointColor = .ibisAccent
                self.ruler?.backgroundColor = color
                self.ruler?.needsDisplay = true
            }
        }

        /// The language the highlighter was last told to use, so `updateNSView`
        /// can notice a Save As that changes the file's type.
        var language: String? { document.highlighter.language }

        /// Reports how far into the buffer this pane can currently see, so the
        /// highlighter parses far enough to cover it and no further.
        func reportViewport() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else { return }
            let visibleRect = scrollView.contentView.bounds
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            document.highlighter.reportViewport(highlighterClientID, charEnd: NSMaxRange(charRange))
        }

        /// Mirrors this pane's effective appearance onto the highlighter, which
        /// picks the light or dark theme from it.
        func syncAppearance() {
            guard let textView else { return }
            document.highlighter.isDark = textView.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }

        /// The system flipped between light and dark: re-theme immediately.
        func appearanceChanged() {
            syncAppearance()
            document.highlighter.refresh()
        }

        /// Refreshes this editor's gutter whenever the *shared* storage's
        /// characters change, so an edit typed in a sibling pane (same document
        /// in a split) updates this pane's line numbers too — its own
        /// `textDidChange` only fires in the pane where the edit happened.
        /// Deferred to the next runloop turn: `updateThickness` measures text
        /// and can retile the scroll view, which must not run from inside
        /// TextKit's editing notifications.
        func observeStorage(_ storage: NSTextStorage) {
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: nil
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    // Attribute-only passes (the syntax highlighter) can't
                    // change line numbers; only react to character edits.
                    guard let storage = notification.object as? NSTextStorage,
                          storage.editedMask.contains(.editedCharacters) else { return }
                    self?.scheduleGutterRefresh()
                }
            }
        }

        private func scheduleGutterRefresh() {
            guard !gutterRefreshScheduled else { return }
            gutterRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.gutterRefreshScheduled = false
                self.ruler?.updateThickness()
                self.ruler?.needsDisplay = true
            }
        }

        /// Give every pane of this document the same document-scoped undo manager
        /// (coherent undo across a split) instead of the shared window one, so
        /// clearing it on a programmatic replace can't wipe another file's history.
        func undoManager(for view: NSTextView) -> UndoManager? {
            document.undoManager
        }

        func textDidChange(_ notification: Notification) {
            // The text lives in the shared storage the text view already edits in
            // place, so there's nothing to copy back — just record the edit
            // (dirty + edit generation for the in-flight-save guard).
            //
            // Neither the gutter nor the highlighter is poked directly here. The
            // storage notification has already scheduled both, and routing this
            // through the same deferred path is what keeps them to one refresh
            // per runloop turn instead of doing the work twice for one keystroke.
            document.registerUserEdit()
            scheduleGutterRefresh()
        }

        // MARK: - Typing colour continuity

        /// What counts as "inside a word" when deciding whether to carry a
        /// token's colour forward onto the characters being typed.
        private static let wordCharacters: CharacterSet = {
            var set = CharacterSet.alphanumerics
            set.insert(charactersIn: "_")
            return set
        }()

        /// Gives text about to be inserted the colour of the token it is being
        /// typed into.
        ///
        /// The editor is a plain-text `NSTextView` (`isRichText = false`), so
        /// insertions take the view's text colour and stay plain until the next
        /// highlight pass reaches them — every word visibly flashes white as it's
        /// typed. No parse is instant, but while the caret sits *inside* a word
        /// that word's classification almost never changes between keystrokes, so
        /// inheriting the neighbouring colour is right nearly always, and a wrong
        /// guess is corrected by the next pass just as the plain colour would be.
        ///
        /// The effect compounds, which is the point: the inherited colour is
        /// written into the inserted character, so the *next* keystroke inherits
        /// from that one. Once any character of a word has been classified, the
        /// rest of the word stays coloured as it's typed.
        ///
        /// Deliberately scoped to mid-word insertions. Inheriting across a space
        /// or newline would be actively wrong — a line typed under a comment
        /// would come out comment-coloured.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            applyTypingStyle(in: textView, at: affectedCharRange, inserting: replacementString)
            return true
        }

        private func applyTypingStyle(in textView: NSTextView, at range: NSRange, inserting replacement: String?) {
            guard let storage = textView.textStorage,
                  range.length == 0,                    // an insertion, not a replacement
                  range.location > 0,
                  range.location <= storage.length,
                  let replacement, !replacement.isEmpty,
                  replacement.unicodeScalars.allSatisfy(Self.wordCharacters.contains),
                  isWordCharacter(at: range.location - 1, in: storage)
            else {
                resetTypingStyle(in: textView)
                return
            }

            let previous = range.location - 1
            var attributes = textView.typingAttributes
            if let color = storage.attribute(.foregroundColor, at: previous, effectiveRange: nil) {
                attributes[.foregroundColor] = color
            }
            // Carried too, so a bold or italic token doesn't reflow mid-word.
            if let font = storage.attribute(.font, at: previous, effectiveRange: nil) {
                attributes[.font] = font
            }
            textView.typingAttributes = attributes
        }

        private func isWordCharacter(at index: Int, in storage: NSTextStorage) -> Bool {
            let text = storage.string as NSString
            guard index >= 0, index < text.length,
                  let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return Self.wordCharacters.contains(scalar)
        }

        /// Back to the plain colour, so a new word doesn't start out wearing the
        /// previous token's colour.
        private func resetTypingStyle(in textView: NSTextView) {
            var attributes = textView.typingAttributes
            attributes[.foregroundColor] = NSColor.textColor
            attributes[.font] = document.highlighter.baseFont
            textView.typingAttributes = attributes
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)),
               document.isBinary == false {
                // Soft tabs: replace Tab with spaces when enabled.
                if let editor = self.textView, softTabsEnabled {
                    let spaces = String(repeating: " ", count: tabWidth)
                    editor.insertText(spaces, replacementRange: editor.selectedRange())
                    return true
                }
            }
            return false
        }

        // Filled in by the representable so the delegate knows the current
        // configuration and how to activate the owning pane.
        var softTabsEnabled = true
        var tabWidth = 4
        var activateHandler: () -> Void = {}
        var lastConfiguration: EditorConfiguration?
        /// The document content version last synced, so a shared-buffer edit from
        /// another pane triggers a single re-highlight rather than a clobber.
        var lastContentVersion = 0
        /// True while a pending-selection application is queued, so repeated
        /// `updateNSView` passes don't schedule it (or clear the flag) twice.
        var pendingSelectionScheduled = false
        /// One-shot: whether this editor's initial viewport positioning has
        /// happened (at mount for a loaded document, or on the first content
        /// arrival for a still-loading one). Once consumed, nothing else may
        /// move the viewport — in particular, not the async highlight pass.
        var hasScrolledToStart = false
        /// The last focus token applied, so a repeated `updateNSView` doesn't
        /// steal focus on every layout pass. Seeded at mount with the pane's
        /// current (monotonic, never-reset) token so only requests issued
        /// *after* mount grab focus.
        var lastFocusRequest = 0

        /// Selections saved at editor teardown, keyed by document id, so
        /// switching tabs A→B→A restores A's caret and approximate scroll
        /// position. Entries are a single `NSRange` per unique document id,
        /// so the cache stays negligibly small and isn't evicted.
        static var savedSelections: [OpenDocument.ID: NSRange] = [:]

        /// Records the current selection so the next mount of this document
        /// (tab switch back) can restore the caret and scroll position.
        func saveSelectionForRemount() {
            guard let textView else { return }
            Self.savedSelections[document.id] = textView.selectedRange()
        }

        /// Initial viewport positioning for a mounted, already-loaded document:
        /// restores the selection saved at the last teardown (tab switch), or
        /// scrolls to the document start on a first-time mount. Only called
        /// when there is no pending selection — that path positions itself and
        /// must win. Never called from the async highlight completion.
        func restoreViewportAfterMount() {
            guard let textView else { return }
            guard let saved = Self.savedSelections[document.id] else {
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                return
            }
            // Defer one turn so the scroll view has its real size (at mount it
            // still has a placeholder frame); does not take first responder.
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView,
                      self.document.pendingSelection == nil else { return }
                let length = (textView.string as NSString).length
                let location = min(saved.location, length)
                let range = NSRange(location: location, length: min(saved.length, length - location))
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            }
        }

        /// One-shot scroll to the leading edge of the document using the
        /// standard text API, unless a pending selection (go-to-line, search
        /// result) will position the viewport itself. Called synchronously
        /// when content first appears — never from async highlight completion.
        func scrollToStartIfNeeded() {
            guard !hasScrolledToStart, let textView else { return }
            hasScrolledToStart = true
            guard document.pendingSelection == nil else { return }
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        /// Removes this pane's layout manager from the document's shared storage
        /// and unregisters it from the document's highlighter (which stops
        /// highlighting entirely once its last pane goes away).
        func detachFromStorage() {
            document.highlighter.detach(highlighterClientID)
            if let layoutManager = textView?.layoutManager,
               let storage = layoutManager.textStorage {
                storage.removeLayoutManager(layoutManager)
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let accentObserver {
                NotificationCenter.default.removeObserver(accentObserver)
            }
            if let storageObserver {
                NotificationCenter.default.removeObserver(storageObserver)
            }
        }
    }
}

/// An `NSTextView` that reports when it becomes first responder (so the owning
/// pane can mark itself active) and when its effective appearance changes (so
/// the editor can re-highlight for the light/dark theme).
final class EditorTextView: NSTextView, SendToAgentResponding {
    var onActivate: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    /// Delivers the current text selection to the agent (wired by `CodeEditorView`).
    var onSendToAgent: ((String) -> Void)?
    /// Name shown in the "Send to <agent>" menu item.
    var agentName = "Agent"

    override func becomeFirstResponder() -> Bool {
        onActivate?()
        // Attribute focus to this editor's window so the MCP `get_selection`
        // tool reads the selection from the correct project window.
        if let window { MCPBridge.shared.noteFocusedEditor(self, in: window) }
        return super.becomeFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// The selected text, or nil when the selection is empty.
    private var agentSelection: String? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        return (string as NSString).substring(with: range)
    }

    @objc var hasAgentSelection: Bool { agentSelection != nil }

    @objc func ibisSendSelectionToAgent(_ sender: Any?) {
        guard let selection = agentSelection else { return }
        onSendToAgent?(selection)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event)
        guard agentSelection != nil else { return baseMenu }
        let menu = baseMenu ?? NSMenu()
        let item = NSMenuItem(
            title: "Send to \(agentName)",
            action: #selector(ibisSendSelectionToAgent(_:)),
            keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }
}

