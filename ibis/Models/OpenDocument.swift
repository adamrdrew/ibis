import Foundation
import Observation
import AppKit

/// A single open file: its live text, dirty state, and load/save. Held by
/// reference in the `Workspace` so the same file shown in multiple tabs/panes
/// stays in sync. Reads and writes happen off the main actor.
///
/// The text lives in a shared `NSTextStorage`, so a file open in several panes
/// is backed by *one* buffer: every pane's `NSTextView` attaches its own layout
/// manager to this storage, and an edit in one pane updates the others natively
/// (preserving each caret/scroll) instead of wholesale-replacing their contents.
@Observable
@MainActor
final class OpenDocument: Identifiable {
    /// Stable identity independent of the URL, so untitled documents (which have
    /// no URL) still have a distinct tab identity and so a document keeps its
    /// identity across a Save As that assigns its URL.
    let id = UUID()
    private(set) var url: URL?

    /// The single backing buffer for the document, shared across all panes. Not
    /// observed (AppKit-managed); programmatic replacements bump `contentVersion`
    /// so editors know to re-sync/re-highlight.
    @ObservationIgnored let storage = NSTextStorage()

    /// Undo manager shared by every pane showing this document (so undo stays
    /// coherent across a split) but *isolated* from other documents — clearing it
    /// on a programmatic replace can't wipe another file's history the way the
    /// shared window undo manager would.
    @ObservationIgnored let undoManager = UndoManager()

    /// Bumped whenever the text is replaced *programmatically* (load, revert,
    /// applied agent edit) so editor views re-highlight and reset scroll. User
    /// typing edits `storage` directly and does not bump this.
    private(set) var contentVersion = 0

    /// Bumped on every content change (typing or programmatic). `save()` captures
    /// it to detect edits that land *during* an in-flight write, so those edits
    /// aren't silently marked clean and dropped.
    private(set) var editGeneration = 0

    /// The document's live text. Reads come straight from the shared storage;
    /// assignment replaces the whole buffer (used by load / revert / agent edits).
    var text: String {
        get { storage.string }
        set { replaceText(newValue) }
    }

    var isDirty = false
    var isLoaded = false
    var isBinary = false
    var loadError: String?

    /// Set when the file couldn't be decoded as UTF-8. The content is shown
    /// (lossily) for reference, but the document is read-only so a save can't
    /// overwrite the original bytes with U+FFFD replacement characters.
    var readOnlyReason: String?
    var isEditable: Bool { readOnlyReason == nil && !isBinary && loadError == nil }

    /// The on-disk modification date/size recorded at the last load or save, used
    /// to detect changes made outside Ibis (e.g. `git checkout`, an agent).
    @ObservationIgnored private var fileModificationDate: Date?
    @ObservationIgnored private var fileSize: Int?

    /// True when the file changed on disk after we loaded/saved it while the
    /// buffer has unsaved edits — so the UI can warn before a clobbering save.
    var hasExternalChanges = false

    /// A range the editor should select and scroll to next time it updates
    /// (used when opening a file from search results). Cleared once applied.
    var pendingSelection: NSRange?

    /// A tab title for documents with no file (ephemeral, agent-created content).
    private var displayTitle: String?

    var name: String { url?.lastPathComponent ?? displayTitle ?? "Untitled" }
    var isUntitled: Bool { url == nil }

    /// How the document is presented: editable source, or a rendered preview.
    /// For files it's derived from the extension; for ephemeral content the
    /// agent declares it.
    enum Format { case source, markdown, html }
    var format: Format

    /// Whether this document can be shown as a rendered preview (Markdown / HTML).
    var isRenderable: Bool { format != .source }

    /// Whether the editor shows the rendered preview (vs. raw source). Renderable
    /// documents open in preview; toggled in the pane header.
    var showsPreview: Bool = false

    init(url: URL) {
        self.url = url
        self.format = Self.format(forExtension: url.pathExtension)
        self.showsPreview = format != .source
    }

    /// A new, empty, untitled buffer. Nothing to read from disk, so it's already
    /// "loaded"; it starts clean and only goes dirty once the user types.
    init() {
        self.url = nil
        self.format = .source
        self.isLoaded = true
    }

    /// An ephemeral, in-memory tab holding agent-supplied content (no file).
    /// Renders per `format`; never nags to save unless the human edits it.
    init(title: String, text: String, format: Format) {
        self.url = nil
        self.displayTitle = title
        self.format = format
        self.isLoaded = true
        self.showsPreview = format != .source
        replaceText(text)
    }

    /// Extensions Ibis renders as previews.
    static func format(forExtension ext: String) -> Format {
        switch ext.lowercased() {
        case "md", "markdown", "mdown", "mkd": .markdown
        case "html", "htm": .html
        default: .source
        }
    }

    /// Assigns a URL in place (used by Save As), keeping the same identity so the
    /// document's tab and editor view are preserved rather than reopened. Updates
    /// the render format to match the chosen extension.
    func assignURL(_ newURL: URL) {
        url = newURL
        displayTitle = nil
        format = Self.format(forExtension: newURL.pathExtension)
    }

    /// Replaces the whole buffer without going through the undo manager, bumping
    /// the version counters so editors re-sync.
    private func replaceText(_ newValue: String) {
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newValue)
        contentVersion += 1
        editGeneration += 1
    }

    /// Records a user edit made directly in the shared storage: marks the buffer
    /// dirty and advances the edit generation (for the in-flight-save check).
    func registerUserEdit() {
        isDirty = true
        editGeneration += 1
    }

    func loadIfNeeded() async {
        guard !isLoaded, let fileURL = url else {
            isLoaded = true
            return
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            OpenDocument.read(fileURL)
        }.value
        apply(outcome)
        isLoaded = true
    }

    /// Applies a read outcome to the document's state.
    private func apply(_ outcome: ReadOutcome) {
        switch outcome {
        case .text(let string, let modified, let size):
            text = string
            isBinary = false
            loadError = nil
            readOnlyReason = nil
            fileModificationDate = modified
            fileSize = size
        case .readOnly(let string, let reason, let modified, let size):
            text = string
            isBinary = false
            loadError = nil
            readOnlyReason = reason
            fileModificationDate = modified
            fileSize = size
        case .binary:
            isBinary = true
        case .failure(let message):
            loadError = message
        }
        hasExternalChanges = false
    }

    /// Saves to disk. Returns `false` for an untitled document (no URL yet) —
    /// the caller must route to Save As — or if the write fails.
    @discardableResult
    func save() async -> Bool {
        guard isEditable, let fileURL = url else { return false }
        // Write to the symlink target, not the link itself, so an atomic replace
        // updates the real file (and keeps the link intact).
        let writeURL = fileURL.resolvingSymlinksInPath()
        let contents = text
        let generation = editGeneration
        let outcome = await Task.detached(priority: .userInitiated) { () -> WriteOutcome in
            do {
                try contents.write(to: writeURL, atomically: true, encoding: .utf8)
                let values = try? writeURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return .success(values?.contentModificationDate, values?.fileSize)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
        switch outcome {
        case .success(let modified, let size):
            fileModificationDate = modified
            fileSize = size
            hasExternalChanges = false
            // Only clear the dirty flag if no newer edits arrived while the write
            // was in flight; otherwise those edits would be lost silently.
            if editGeneration == generation { isDirty = false }
            return true
        case .failure:
            return false
        }
    }

    /// Re-reads the file from disk, discarding unsaved edits. No-op for an
    /// untitled document. Uses the same read path as the initial load.
    func revertToSaved() async {
        guard let fileURL = url else { return }
        let outcome = await Task.detached(priority: .userInitiated) {
            OpenDocument.read(fileURL)
        }.value
        apply(outcome)
        isDirty = false
    }

    // MARK: - External-modification detection

    /// Checks the on-disk modification date/size against what we recorded. A
    /// clean buffer is reloaded to match disk; a dirty buffer is flagged so the
    /// UI can warn the user before they clobber the external change.
    func reconcileWithDisk() async {
        guard let fileURL = url, isLoaded, !isBinary, loadError == nil else { return }
        let current = await Task.detached(priority: .utility) { () -> (Date?, Int?)? in
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (values.contentModificationDate, values.fileSize)
        }.value
        guard let current else { return }
        let unchanged = current.0 == fileModificationDate && current.1 == fileSize
        guard !unchanged else { return }
        if isDirty {
            hasExternalChanges = true
        } else {
            await revertToSaved()
        }
    }

    // MARK: - Reading

    private enum ReadOutcome: Sendable {
        case text(String, Date?, Int?)
        case readOnly(String, reason: String, Date?, Int?)
        case binary
        case failure(String)
    }

    private enum WriteOutcome: Sendable {
        case success(Date?, Int?)
        case failure(String)
    }

    nonisolated private static func read(_ url: URL) -> ReadOutcome {
        do {
            let data = try Data(contentsOf: url)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate
            let size = values?.fileSize
            if isProbablyBinary(data) {
                return .binary
            }
            // Decode strictly: a byte sequence that isn't valid UTF-8 must not be
            // round-tripped (that replaces every non-ASCII byte with U+FFFD and a
            // save would then destroy the original bytes). Show it read-only.
            if let string = String(data: data, encoding: .utf8) {
                return .text(string, modified, size)
            }
            let lossy = String(decoding: data, as: UTF8.self)
            return .readOnly(
                lossy,
                reason: "This file isn’t valid UTF-8. It’s shown read-only so saving can’t corrupt it.",
                modified,
                size
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Heuristic: a NUL byte in the first several KB almost always means binary.
    nonisolated private static func isProbablyBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }
}
