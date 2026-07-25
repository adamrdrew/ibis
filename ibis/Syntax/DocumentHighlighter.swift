import AppKit

/// Owns syntax highlighting for one document.
///
/// Highlighting is per *document*, not per pane. Every pane showing a file
/// attaches its own layout manager to one shared `NSTextStorage` (see
/// `OpenDocument.storage`), so colouring that storage once updates all of them —
/// running it per pane meant a split performed two identical full-document
/// passes over the same buffer, queued behind each other on the one serialized
/// `SyntaxHighlighter` actor.
///
/// Three things keep typing smooth, each measured against the old behaviour:
///
/// * **Prefix-limited passes.** highlight.js has no incremental API, but it does
///   parse linearly, so highlighting `[0, limit)` yields exactly the colours a
///   whole-file parse would produce for that prefix. We parse only as far as the
///   deepest viewport any pane has scrolled to, plus a look-ahead margin.
///   Truncating at the *end* is always safe; starting partway in would not be,
///   because a chunk beginning inside a block comment or a multi-line string has
///   no way to know that — which is why this limits the end and never the start.
///
/// * **Diff application** (`write(_:_:over:)`). Applying an attribute
///   invalidates TextKit layout across the range it touches, so rewriting the
///   whole document's colours forced a full relayout on the main thread — 14 ms
///   at 1,700 lines, 43 ms at 5,100, every pass, versus 0 ms when nothing is
///   written. Comparing before writing means an ordinary keystroke changes no
///   attributes at all and costs nothing.
///
/// * **Real cancellation**, in `SyntaxHighlighter.highlight`.
@MainActor
final class DocumentHighlighter {
    /// Above this many UTF-16 units a pass costs more than it's worth (a 210 KB
    /// parse measures ~340 ms), so we stop rather than pay it. This is the same
    /// ceiling the old whole-file path used; the difference is that the budget
    /// now buys the prefix the user is actually looking at, so a large file is
    /// coloured near the top instead of not being coloured at all.
    private static let prefixCap = 200_000

    /// Never parse less than this. A freshly mounted editor's text view still
    /// has a placeholder frame, so its visible rect is meaningless — this floor
    /// (~400 lines) makes the first paint come up fully coloured anyway.
    private static let minimumLimit = 16_000

    /// How far past the deepest viewport to parse, so ordinary scrolling stays
    /// ahead of the highlighter instead of scheduling a pass per scroll tick.
    private static let lookAhead = 20_000

    /// How long after the last edit to fill in the rest of a file that was only
    /// parsed as far as the viewport.
    private static let idleFullPassDelay = 1_200

    private let storage: NSTextStorage
    private var storageObserver: NSObjectProtocol?

    // MARK: - Style inputs
    //
    // Pushed by the attached editors. A document lives in exactly one window and
    // the font/theme settings are app-wide, so "last writer wins" across panes is
    // not a real ambiguity.

    var language: String?
    var lightThemeName = EditorTheme.light
    var darkThemeName = EditorTheme.dark
    var isDark = false
    var baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var fontName = "SF Mono"
    var fontSize: Double = 13

    /// One attached editor pane. Panes share the buffer's colours but each owns
    /// the chrome (text-view and gutter background) that has to match the theme.
    private final class Client {
        var visibleEnd = 0
        let onBackground: (RGBAColor?) -> Void
        init(onBackground: @escaping (RGBAColor?) -> Void) {
            self.onBackground = onBackground
        }
    }
    private var clients: [UUID: Client] = [:]

    private var task: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    /// True from the moment a pass captures its text until it has applied. Only
    /// one pass runs at a time: an edit arriving mid-pass sets `needsAnotherPass`
    /// rather than cancelling and restarting, which is what lets the in-flight
    /// result still be used (see `editFloor`).
    private var isRunning = false
    private var needsAnotherPass = false

    /// The lowest offset edited since the running pass captured its text, or
    /// `Int.max` if nothing has been touched.
    ///
    /// This is what keeps colouring up with the caret. A parse takes ~110 ms on
    /// an 80 KB file, so at any normal typing speed a keystroke lands before it
    /// finishes — and discarding the whole result for that (as this did at
    /// first, and as the pre-existing whole-document string comparison did
    /// before it) means nothing is ever applied *while* typing, only during
    /// pauses long enough for a pass to run start to finish. But an edit at
    /// offset F cannot change the correct colouring of anything before F, so the
    /// result is still valid over `[0, F)`. Applying that much keeps the
    /// highlighting current everywhere except the few characters just typed.
    private var editFloor = Int.max

    /// How far into the buffer the last applied pass reached, so scrolling only
    /// schedules work when it runs past what has already been coloured.
    private(set) var highlightedThrough = 0

    /// The theme background from the last pass, replayed to panes that attach
    /// later so a new pane in a split doesn't flash the default background.
    private var background: RGBAColor?

    init(storage: NSTextStorage) {
        self.storage = storage
        // Observing the storage (rather than each pane's `textDidChange`) is what
        // makes this per-document: it sees edits typed in any pane, and
        // programmatic replacements (load, revert, an applied agent edit) too.
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let edited = notification.object as? NSTextStorage,
                      edited.editedMask.contains(.editedCharacters) else { return }
                self?.textDidChange(editedFrom: edited.editedRange.location)
            }
        }
    }

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
    }

    // MARK: - Attachment

    /// Registers a pane. `onBackground` delivers the theme background for the
    /// pane's text view and gutter; it fires immediately with the last known
    /// value so a pane attaching mid-session matches its siblings.
    func attach(_ id: UUID, onBackground: @escaping (RGBAColor?) -> Void) {
        clients[id] = Client(onBackground: onBackground)
        onBackground(background)
    }

    func detach(_ id: UUID) {
        clients.removeValue(forKey: id)
        guard clients.isEmpty else { return }
        task?.cancel()
        task = nil
        idleTask?.cancel()
        idleTask = nil
    }

    /// Reports how far into the buffer a pane can currently see. Scheduling is
    /// self-throttling: because a pass parses `lookAhead` characters beyond the
    /// viewport, scrolling within that margin schedules nothing.
    func reportViewport(_ id: UUID, charEnd: Int) {
        guard let client = clients[id], client.visibleEnd != charEnd else { return }
        client.visibleEnd = charEnd
        guard charEnd > highlightedThrough, highlightedThrough < storage.length else { return }
        schedule(debounced: true)
    }

    // MARK: - Scheduling

    /// Runs a pass without debouncing: mount, a language / theme / font change,
    /// an appearance flip, or a programmatic content replacement.
    func refresh() {
        schedule(debounced: false)
    }

    /// Awaits the in-flight pass, if any. A test seam: passes are fire-and-forget
    /// in normal use, and there is otherwise no way to observe one completing.
    func awaitCurrentPass() async {
        await task?.value
    }

    private func textDidChange(editedFrom location: Int) {
        editFloor = min(editFloor, location)
        schedule(debounced: true)
    }

    private func schedule(debounced: Bool) {
        // A pass is already parsing. Don't cancel it — it will still produce a
        // result that is valid up to `editFloor`, which is most of the buffer.
        // Just queue a follow-up for when it lands.
        guard !isRunning else {
            needsAnotherPass = true
            return
        }
        task?.cancel()
        idleTask?.cancel()
        idleTask = nil
        // Deliberately the cheap estimate, not `effectiveLimit`: `schedule` runs
        // synchronously inside TextKit's edit notification, and the estimate
        // doesn't touch the buffer's characters.
        let delay = Self.debounce(forLimit: estimatedLimit)
        task = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            guard let self, !Task.isCancelled else { return }
            // Recomputed after the debounce: the viewport may have moved while
            // we waited.
            await self.run(limit: self.effectiveLimit)
        }
    }

    /// The debounce exists only to avoid parsing on literally every keystroke —
    /// *not* to stop passes overlapping, which `isRunning` handles structurally.
    /// Keep it short: it is a floor on how far behind the caret the colouring can
    /// fall, and every millisecond here is a millisecond of visible lag. An
    /// earlier version scaled this to 250/450 ms to prevent pile-ups and made
    /// highlighting noticeably laggier than the whole-document version it
    /// replaced.
    private static func debounce(forLimit limit: Int) -> Int {
        limit < 100_000 ? 100 : 250
    }

    /// How far a pass would parse, without consulting the buffer's characters —
    /// enough to pick a debounce, and safe to compute from inside a TextKit edit
    /// notification.
    private var estimatedLimit: Int {
        let deepest = clients.values.map(\.visibleEnd).max() ?? 0
        return min(max(deepest + Self.lookAhead, Self.minimumLimit), storage.length)
    }

    /// How far to parse: through the deepest viewport plus the look-ahead,
    /// snapped forward to a line boundary so a pass never cuts a line in half.
    /// Returns 0 when the prefix the panes need is too large to be worth
    /// parsing — the text beyond simply stays uncoloured rather than being
    /// stripped of colours it already has.
    private var effectiveLimit: Int {
        let length = storage.length
        guard length > 0 else { return 0 }
        var limit = max(estimatedLimit, Self.minimumLimit)
        if limit >= length {
            limit = length
        } else {
            let text = storage.string as NSString
            limit = NSMaxRange(text.lineRange(for: NSRange(location: limit, length: 0)))
        }
        return limit > Self.prefixCap ? 0 : limit
    }

    // MARK: - Running

    private func run(limit: Int) async {
        isRunning = true
        // Everything from here is unchanged as far as this pass knows; the
        // storage observer lowers this if the user types while we parse.
        editFloor = Int.max

        await performPass(limit: limit)

        isRunning = false
        // An edit arrived mid-pass. Go again, so the region around the caret —
        // the part this pass had to leave alone — catches up.
        if needsAnotherPass {
            needsAnotherPass = false
            schedule(debounced: true)
        }
    }

    private func performPass(limit: Int) async {
        // An unrecognised extension has no grammar: reset to plain text. This is
        // distinct from `limit == 0` (a prefix too large to parse), which must
        // leave existing colours alone rather than strip them.
        guard let language else {
            applyPlain()
            return
        }
        let length = storage.length
        let bounded = min(limit, length)
        guard bounded > 0 else { return }

        let text = storage.string as NSString
        let code = bounded >= text.length ? (text as String) : text.substring(to: bounded)
        let theme = isDark ? darkThemeName : lightThemeName

        let result = await SyntaxHighlighter.shared.highlight(
            code: code,
            language: language,
            theme: theme,
            fontName: fontName,
            fontSize: fontSize
        )
        guard let result else { return }

        // Apply as much as is still true. Edits made while we parsed invalidate
        // everything from the first edited offset onwards (later runs are
        // shifted), but nothing before it — so colour up to there rather than
        // throwing the whole pass away.
        let applicable = min(bounded, editFloor, storage.length)
        guard applicable > 0 else { return }

        apply(result, upTo: applicable)
        highlightedThrough = applicable
        scheduleIdleFullPass()
    }

    /// Once the viewport-limited pass has settled, colour the rest of the file so
    /// scrolling doesn't reveal uncoloured text. Only for files small enough to
    /// parse whole; larger ones stay viewport-driven.
    private func scheduleIdleFullPass() {
        idleTask?.cancel()
        idleTask = nil
        let length = storage.length
        guard highlightedThrough < length, length <= Self.prefixCap else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.idleFullPassDelay))
            guard let self, !Task.isCancelled else { return }
            await self.run(limit: self.storage.length)
        }
    }

    // MARK: - Applying

    private func apply(_ result: HighlightResult, upTo limit: Int) {
        let fontManager = NSFontManager.shared
        let bounds = NSRange(location: 0, length: min(limit, storage.length))
        guard bounds.length > 0 else { return }

        storage.beginEditing()
        for run in result.runs {
            let range = NSIntersectionRange(run.range, bounds)
            guard range.length > 0 else { continue }
            var font = baseFont
            if run.isBold { font = fontManager.convert(font, toHaveTrait: .boldFontMask) }
            if run.isItalic { font = fontManager.convert(font, toHaveTrait: .italicFontMask) }
            write(.foregroundColor, run.color.nsColor, over: range)
            write(.font, font, over: range)
        }
        storage.endEditing()

        // The runs returned by `SyntaxHighlighter` tile the parsed range
        // contiguously (`enumerateAttributes` yields unstyled spans too), so
        // there are no gaps needing a default-colour sweep — which is what lets
        // this method touch nothing at all when nothing changed.

        publish(background: result.background)
    }

    /// Resets the parsed text to the default colour, for documents with no
    /// recognised language.
    private func applyPlain() {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        storage.beginEditing()
        write(.foregroundColor, NSColor.textColor, over: full)
        write(.font, baseFont, over: full)
        storage.endEditing()
        highlightedThrough = full.length
        publish(background: nil)
    }

    private func publish(background newValue: RGBAColor?) {
        background = newValue
        for client in clients.values {
            client.onBackground(newValue)
        }
    }

    /// Writes an attribute only where the storage doesn't already carry it.
    ///
    /// This is the hot path, and the reason typing is cheap: `addAttribute`
    /// invalidates TextKit layout over the range it touches *even when the value
    /// is identical*, so the write has to be skipped outright rather than merely
    /// made idempotent. After a keystroke the recomputed colours match what the
    /// storage already holds (attribute ranges shift with the edit), so a pass
    /// over a 5,100-line file performs zero writes and forces no relayout.
    private func write(_ key: NSAttributedString.Key, _ value: NSObject, over range: NSRange) {
        var effective = NSRange(location: 0, length: 0)
        let existing = storage.attribute(key, at: range.location, effectiveRange: &effective) as? NSObject
        if let existing, existing.isEqual(value), NSMaxRange(effective) >= NSMaxRange(range) {
            return
        }
        storage.addAttribute(key, value: value, range: range)
    }
}
