import Foundation

/// A lightweight, `Sendable` snapshot of a directory entry, produced off the
/// main actor and turned into `FileNode`s on the main actor.
struct FileEntry: Sendable {
    let url: URL
    let isDirectory: Bool
}

/// Reads directory contents for the file tree. Hidden dotfiles (like
/// `.gitignore`, `.env`) are shown — developers want them — but noise like
/// `.DS_Store` and the `.git` directory are hidden.
enum FileTreeLoader {
    static let ignoredNames: Set<String> = [".DS_Store", ".git"]

    nonisolated static func contents(of directory: URL) -> [FileEntry] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        let entries = urls.compactMap { url -> FileEntry? in
            guard !ignoredNames.contains(url.lastPathComponent) else { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileEntry(url: url, isDirectory: isDirectory)
        }

        // Directories first, then case-insensitive natural ordering by name.
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.url.lastPathComponent
                .localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }
}
