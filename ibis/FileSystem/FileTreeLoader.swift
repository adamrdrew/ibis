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
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        let entries = urls.compactMap { url -> FileEntry? in
            guard !ignoredNames.contains(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var isDirectory = values?.isDirectory ?? false
            if !isDirectory, values?.isSymbolicLink == true {
                // `isDirectoryKey` doesn't follow symlinks, so a linked folder
                // (a monorepo package, a linked node_modules) would render as a
                // plain file — unexpandable, and opening it as a document fails.
                // Classify by the link's destination instead.
                var resolvedIsDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &resolvedIsDirectory) {
                    isDirectory = resolvedIsDirectory.boolValue
                }
            }
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
