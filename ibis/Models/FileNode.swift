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
    /// Orders overlapping async directory reads. FSEvents can enqueue another
    /// reload while an earlier slow-volume scan is suspended; only the newest
    /// result may replace the tree.
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var latestDirectoryRead: (generation: Int, task: Task<[FileEntry], Never>)?

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

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let directory = url
        let task = Task.detached(priority: .userInitiated) {
            FileTreeLoader.contents(of: directory)
        }
        latestDirectoryRead = (generation, task)
        guard let entries = await newestEntries(startingWith: (generation, task)) else { return }
        children = entries.map { FileNode(url: $0.url, isDirectory: $0.isDirectory) }
        hasLoaded = true
        isLoading = false
        latestDirectoryRead = nil
    }

    /// Synchronously loads children if needed. Used by the `NSOutlineView` data
    /// source, which is synchronous; reading one directory is fast.
    func loadChildrenSyncIfNeeded() {
        guard isDirectory, !hasLoaded else { return }
        // Supersede an async read that may already be in flight.
        loadGeneration += 1
        latestDirectoryRead = nil
        children = FileTreeLoader.contents(of: url).map {
            FileNode(url: $0.url, isDirectory: $0.isDirectory)
        }
        hasLoaded = true
        isLoading = false
    }

    /// Re-reads the directory but keeps existing child nodes for URLs that still
    /// exist, so expansion/loaded state of surviving subtrees is preserved. Used
    /// when the filesystem changes under a loaded directory.
    func reloadChildrenMerging() async {
        guard isDirectory, hasLoaded else { return }

        loadGeneration += 1
        let generation = loadGeneration
        let directory = url
        let task = Task.detached(priority: .userInitiated) {
            FileTreeLoader.contents(of: directory)
        }
        latestDirectoryRead = (generation, task)

        guard let entries = await newestEntries(startingWith: (generation, task)) else { return }
        var existing: [URL: FileNode] = [:]
        for child in children ?? [] {
            existing[child.url] = child
        }
        children = entries.map { entry in
            // Reuse only when the entry is still the same *kind* — `isDirectory`
            // is immutable on the node, so a path replaced by the other kind
            // (`rm notes && mkdir notes` coalesced into one reload) must get a
            // fresh node or it keeps the stale type forever.
            if let node = existing[entry.url], node.isDirectory == entry.isDirectory {
                return node
            }
            return FileNode(url: entry.url, isDirectory: entry.isDirectory)
        }
        latestDirectoryRead = nil
    }

    /// Awaits the newest read when this one is superseded. Besides preventing
    /// stale data from winning, this preserves the contract that returning from
    /// an awaited reload means the latest requested snapshot is installed.
    private func newestEntries(
        startingWith initial: (generation: Int, task: Task<[FileEntry], Never>)
    ) async -> [FileEntry]? {
        var pending = initial
        while true {
            let entries = await pending.task.value
            guard pending.generation != loadGeneration else {
                return entries
            }
            guard let latestDirectoryRead else {
                // A synchronous load superseded the async work and has already
                // installed the current snapshot.
                return nil
            }
            pending = latestDirectoryRead
        }
    }

    var isLoaded: Bool { hasLoaded }
}
