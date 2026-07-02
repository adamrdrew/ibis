import Foundation
import Observation

/// The live state for a single window: the opened folder (or file), its file
/// tree, and (in later phases) open tabs and pane layout.
@Observable
final class Workspace {
    let rootURL: URL
    let isDirectory: Bool
    let rootNode: FileNode
    let layout = EditorLayout()

    /// Holds security-scoped access to the root open for the workspace's lifetime.
    private let access: SecurityScopedAccess

    /// Open documents, keyed by URL, so the same file reused across tabs/panes
    /// shares one text buffer and unsaved edits survive switching away and back.
    private var documentCache: [URL: OpenDocument] = [:]

    init(rootURL: URL, isDirectory: Bool) {
        self.rootURL = rootURL
        self.isDirectory = isDirectory
        self.access = SecurityScopedAccess(url: rootURL)
        self.rootNode = FileNode(url: rootURL, isDirectory: isDirectory)
    }

    var displayName: String {
        rootURL.lastPathComponent
    }

    /// Returns the cached document for a URL, creating (but not yet loading) one
    /// on first request.
    func document(for url: URL) -> OpenDocument {
        if let existing = documentCache[url] {
            return existing
        }
        let document = OpenDocument(url: url)
        documentCache[url] = document
        return document
    }
}
