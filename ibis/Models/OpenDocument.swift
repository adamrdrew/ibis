import Foundation
import Observation

/// A single open file: its live text, dirty state, and load/save. Held by
/// reference in the `Workspace` so the same file shown in multiple tabs/panes
/// stays in sync. Reads and writes happen off the main actor.
@Observable
final class OpenDocument: Identifiable {
    /// Stable identity independent of the URL, so untitled documents (which have
    /// no URL) still have a distinct tab identity and so a document keeps its
    /// identity across a Save As that assigns its URL.
    let id = UUID()
    private(set) var url: URL?
    var text: String = ""
    var isDirty = false
    var isLoaded = false
    var isBinary = false
    var loadError: String?

    /// A range the editor should select and scroll to next time it updates
    /// (used when opening a file from search results). Cleared once applied.
    var pendingSelection: NSRange?

    var name: String { url?.lastPathComponent ?? "Untitled" }
    var isUntitled: Bool { url == nil }

    init(url: URL) {
        self.url = url
    }

    /// A new, empty, untitled buffer. Nothing to read from disk, so it's already
    /// "loaded"; it starts clean and only goes dirty once the user types.
    init() {
        self.url = nil
        self.isLoaded = true
    }

    /// Assigns a URL in place (used by Save As), keeping the same identity so the
    /// document's tab and editor view are preserved rather than reopened.
    func assignURL(_ newURL: URL) {
        url = newURL
    }

    func loadIfNeeded() async {
        guard !isLoaded, let fileURL = url else {
            isLoaded = true
            return
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            OpenDocument.read(fileURL)
        }.value
        switch outcome {
        case .text(let string):
            text = string
            isBinary = false
            loadError = nil
        case .binary:
            isBinary = true
        case .failure(let message):
            loadError = message
        }
        isLoaded = true
    }

    /// Saves to disk. Returns `false` for an untitled document (no URL yet) —
    /// the caller must route to Save As — or if the write fails.
    @discardableResult
    func save() async -> Bool {
        guard let fileURL = url, !isBinary, loadError == nil else { return false }
        let contents = text
        let succeeded = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                try contents.write(to: fileURL, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }.value
        if succeeded {
            isDirty = false
        }
        return succeeded
    }

    /// Writes to disk synchronously. Used on window close, where the decision to
    /// proceed must be made before the window goes away.
    @discardableResult
    func saveSynchronously() -> Bool {
        guard let url, !isBinary, loadError == nil else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            return true
        } catch {
            return false
        }
    }

    // MARK: - Reading

    private enum ReadOutcome: Sendable {
        case text(String)
        case binary
        case failure(String)
    }

    nonisolated private static func read(_ url: URL) -> ReadOutcome {
        do {
            let data = try Data(contentsOf: url)
            if isProbablyBinary(data) {
                return .binary
            }
            return .text(String(decoding: data, as: UTF8.self))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Heuristic: a NUL byte in the first several KB almost always means binary.
    nonisolated private static func isProbablyBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }
}
