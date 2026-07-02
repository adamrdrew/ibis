import Foundation
import AppKit

/// Filesystem mutations for the file browser. All operate within the workspace's
/// security-scoped subtree. The FSEvents watcher refreshes the tree, and callers
/// also reload the affected directory for immediacy.
enum FileOperations {
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return url }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    @discardableResult
    static func createFile(in directory: URL, baseName: String = "untitled") throws -> URL {
        let destination = uniqueURL(in: directory, baseName: baseName)
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    @discardableResult
    static func createFolder(in directory: URL, baseName: String = "untitled folder") throws -> URL {
        let destination = uniqueURL(in: directory, baseName: baseName)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return destination
    }

    /// A URL in `directory` that doesn't collide with an existing item, appending
    /// " 2", " 3", … to the stem as needed.
    static func uniqueURL(in directory: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        let candidate = directory.appendingPathComponent(baseName)
        guard fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) else {
            return candidate
        }
        let ext = (baseName as NSString).pathExtension
        let stem = (baseName as NSString).deletingPathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: next.path(percentEncoded: false)) {
                return next
            }
            index += 1
        }
    }

    // MARK: - Shell integrations

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openInTerminal(_ directory: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return
        }
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
