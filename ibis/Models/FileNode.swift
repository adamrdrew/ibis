import Foundation
import Observation

/// A node in the workspace file tree. Children are loaded lazily the first time
/// a directory is expanded, so the tree scales to arbitrarily deep folders
/// without reading the whole hierarchy up front.
@Observable
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool

    /// `nil` until the directory's contents have been loaded.
    var children: [FileNode]?
    var isExpanded = false
    var isLoading = false

    private var hasLoaded = false

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Loads (or reloads) the directory's immediate children off the main actor.
    func loadChildren(reload: Bool = false) async {
        guard isDirectory else { return }
        guard reload || !hasLoaded else { return }

        isLoading = true
        let directory = url
        let entries = await Task.detached(priority: .userInitiated) {
            FileTreeLoader.contents(of: directory)
        }.value
        children = entries.map { FileNode(url: $0.url, isDirectory: $0.isDirectory) }
        hasLoaded = true
        isLoading = false
    }
}
