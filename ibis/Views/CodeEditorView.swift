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
            coordinator?.scheduleHighlight(debounced: false)
        }
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

        // The shared storage already holds the text; no need to assign a string.
        configure(textView, in: scrollView, ruler: ruler)
        syncCoordinator(context.coordinator)
        context.coordinator.language = Language.highlightName(for: document.url)
        context.coordinator.lastContentVersion = document.contentVersion
        context.coordinator.hasScrolledToStart = false
        context.coordinator.suppressStartScroll = document.pendingSelection != nil
        context.coordinator.scheduleHighlight(debounced: false)

        return scrollView
    }

    /// Detaches this pane's layout manager from the shared storage when the pane
    /// goes away, so closing/reopening panes doesn't accumulate layout managers
    /// (and redundant highlight passes) on a long-lived document buffer.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detachFromStorage()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView,
              let ruler = context.coordinator.ruler else { return }

        var needsHighlight = false
        // The buffer is shared, so a *programmatic* replacement (load, revert,
        // applied agent edit) is already reflected here; we only need to
        // re-highlight, reset scroll, and drop stale undo actions (whose ranges
        // now point past the new, possibly shorter, backing store — undoing them
        // would throw an out-of-bounds exception).
        if context.coordinator.lastContentVersion != document.contentVersion {
            context.coordinator.lastContentVersion = document.contentVersion
            needsHighlight = true
            context.coordinator.hasScrolledToStart = false
            context.coordinator.suppressStartScroll = document.pendingSelection != nil
            // Clear only *this document's* undo stack. Because the text view uses
            // the document-scoped undo manager (see undoManager(for:)), this can't
            // wipe another file's history shown in a sibling pane.
            document.undoManager.removeAllActions()
        }

        let configChanged = context.coordinator.lastConfiguration != configuration
        if configChanged { needsHighlight = true }

        // The URL can change under a stable document (Save As of an untitled
        // buffer), which may change the language — refresh it.
        let language = Language.highlightName(for: document.url)
        if context.coordinator.language != language {
            context.coordinator.language = language
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

        if needsHighlight {
            context.coordinator.scheduleHighlight(debounced: false)
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

    /// Pushes the current representable values the coordinator needs.
    private func syncCoordinator(_ coordinator: Coordinator) {
        coordinator.softTabsEnabled = configuration.usesSoftTabs
        coordinator.tabWidth = configuration.tabWidth
        coordinator.activateHandler = onActivate
        coordinator.baseFont = makeFont()
        coordinator.fontName = configuration.fontName
        coordinator.fontSize = configuration.fontSize
        coordinator.lightThemeName = configuration.lightTheme
        coordinator.darkThemeName = configuration.darkTheme
        coordinator.lastConfiguration = configuration
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
                }
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
            // place, so there's nothing to copy back — just record the edit (dirty
            // + edit generation for the in-flight-save guard) and re-highlight.
            document.registerUserEdit()
            ruler?.updateThickness()
            ruler?.needsDisplay = true
            scheduleHighlight(debounced: true)
        }

        // MARK: - Syntax highlighting

        /// Runs a highlight pass, optionally after a short debounce so typing
        /// stays smooth. Supersedes any in-flight pass.
        func scheduleHighlight(debounced: Bool) {
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                if debounced {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                guard let self, !Task.isCancelled else { return }
                await self.performHighlight()
            }
        }

        private func performHighlight() async {
            guard let language else {
                applyPlainColors()
                return
            }
            guard let textView else { return }
            let code = textView.string
            // Skip pathologically large files to avoid blocking on the JS engine.
            guard (code as NSString).length <= 200_000 else {
                applyPlainColors()
                return
            }

            let isDark = textView.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let theme = isDark ? darkThemeName : lightThemeName

            let result = await SyntaxHighlighter.shared.highlight(
                code: code,
                language: language,
                theme: theme,
                fontName: fontName,
                fontSize: fontSize
            )

            guard let result, !Task.isCancelled,
                  let liveTextView = self.textView,
                  let storage = liveTextView.textStorage,
                  liveTextView.string == code,
                  storage.length == result.sourceLength else { return }

            apply(result, to: liveTextView, storage: storage)
        }

        private func apply(_ result: HighlightResult, to textView: NSTextView, storage: NSTextStorage) {
            let fontManager = NSFontManager.shared
            let full = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            storage.addAttribute(.font, value: baseFont, range: full)

            for run in result.runs {
                let range = NSIntersectionRange(run.range, full)
                guard range.length > 0 else { continue }
                storage.addAttribute(.foregroundColor, value: run.color.nsColor, range: range)
                if run.isBold || run.isItalic {
                    var font = baseFont
                    if run.isBold { font = fontManager.convert(font, toHaveTrait: .boldFontMask) }
                    if run.isItalic { font = fontManager.convert(font, toHaveTrait: .italicFontMask) }
                    storage.addAttribute(.font, value: font, range: range)
                }
            }
            storage.endEditing()

            let backgroundColor = result.background?.nsColor ?? .textBackgroundColor
            textView.backgroundColor = backgroundColor
            textView.insertionPointColor = .ibisAccent
            ruler?.backgroundColor = backgroundColor
            ruler?.needsDisplay = true

            scrollToStartIfNeeded()
        }

        /// Resets the document to the default text color (used for unrecognized
        /// or oversized files).
        private func applyPlainColors() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            storage.addAttribute(.font, value: baseFont, range: full)
            storage.endEditing()
            textView.backgroundColor = NSColor.textBackgroundColor
            ruler?.backgroundColor = NSColor.textBackgroundColor

            scrollToStartIfNeeded()
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
        var baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
        var fontName = "SF Mono"
        var fontSize: Double = 13
        var lightThemeName = EditorTheme.light
        var darkThemeName = EditorTheme.dark
        var language: String?
        var lastConfiguration: EditorConfiguration?
        /// The document content version last synced, so a shared-buffer edit from
        /// another pane triggers a single re-highlight rather than a clobber.
        var lastContentVersion = 0
        /// True while a pending-selection application is queued, so repeated
        /// `updateNSView` passes don't schedule it (or clear the flag) twice.
        var pendingSelectionScheduled = false
        /// One-shot: after a document loads, scroll to the very start so the
        /// text isn't left offset a few characters to the right. Suppressed when
        /// the document opened with a target selection (e.g. from search).
        var hasScrolledToStart = false
        var suppressStartScroll = false
        /// The last focus token applied, so a repeated `updateNSView` doesn't
        /// steal focus on every layout pass.
        var lastFocusRequest = 0
        private var highlightTask: Task<Void, Never>?

        /// Scrolls the editor to the leading edge of the document using the
        /// standard text API. Safe to call at any time.
        func scrollToStartIfNeeded() {
            guard !hasScrolledToStart, !suppressStartScroll, let textView else { return }
            hasScrolledToStart = true
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        /// Removes this pane's layout manager from the document's shared storage.
        func detachFromStorage() {
            highlightTask?.cancel()
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
        }
    }
}

/// An `NSTextView` that reports when it becomes first responder (so the owning
/// pane can mark itself active) and when its effective appearance changes (so
/// the editor can re-highlight for the light/dark theme).
final class EditorTextView: NSTextView {
    var onActivate: (() -> Void)?
    var onAppearanceChange: (() -> Void)?

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
}

