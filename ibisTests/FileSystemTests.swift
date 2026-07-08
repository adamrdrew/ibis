import Testing
import Foundation
import AppKit
@testable import Ibis

// MARK: - FileTreeLoader

@Suite struct FileTreeLoaderTests {
    @Test func hidesNoiseButShowsDotfiles() throws {
        try TestSupport.withTempDir { dir in
            let fm = FileManager.default
            fm.createFile(atPath: dir.appending(path: ".DS_Store").path, contents: Data())
            try fm.createDirectory(at: dir.appending(path: ".git"), withIntermediateDirectories: false)
            fm.createFile(atPath: dir.appending(path: ".gitignore").path, contents: Data())
            fm.createFile(atPath: dir.appending(path: "main.swift").path, contents: Data())

            let names = FileTreeLoader.contents(of: dir).map(\.url.lastPathComponent)
            #expect(!names.contains(".DS_Store"))
            #expect(!names.contains(".git"))
            #expect(names.contains(".gitignore"))
            #expect(names.contains("main.swift"))
        }
    }

    @Test func directoriesSortFirstThenNaturalOrder() throws {
        try TestSupport.withTempDir { dir in
            let fm = FileManager.default
            fm.createFile(atPath: dir.appending(path: "aardvark.txt").path, contents: Data())
            fm.createFile(atPath: dir.appending(path: "File10.txt").path, contents: Data())
            fm.createFile(atPath: dir.appending(path: "file2.txt").path, contents: Data())
            try fm.createDirectory(at: dir.appending(path: "zebra"), withIntermediateDirectories: false)

            let entries = FileTreeLoader.contents(of: dir)
            #expect(entries.first?.url.lastPathComponent == "zebra")
            #expect(entries.first?.isDirectory == true)
            // Natural (numeric-aware), case-insensitive ordering of the files.
            #expect(entries.dropFirst().map(\.url.lastPathComponent) == ["aardvark.txt", "file2.txt", "File10.txt"])
        }
    }

    @Test func symlinkToDirectoryClassifiesAsDirectory() throws {
        try TestSupport.withTempDir { dir in
            let fm = FileManager.default
            let real = dir.appending(path: "real")
            try fm.createDirectory(at: real, withIntermediateDirectories: false)
            try fm.createSymbolicLink(
                at: dir.appending(path: "link"),
                withDestinationURL: real
            )
            let entries = FileTreeLoader.contents(of: dir)
            let link = entries.first { $0.url.lastPathComponent == "link" }
            #expect(link?.isDirectory == true)
        }
    }

    @Test func danglingSymlinkClassifiesAsFile() throws {
        try TestSupport.withTempDir { dir in
            try FileManager.default.createSymbolicLink(
                at: dir.appending(path: "broken"),
                withDestinationURL: dir.appending(path: "gone")
            )
            let entries = FileTreeLoader.contents(of: dir)
            let broken = entries.first { $0.url.lastPathComponent == "broken" }
            #expect(broken != nil)
            #expect(broken?.isDirectory == false)
        }
    }

    @Test func missingDirectoryYieldsEmpty() {
        let bogus = URL(filePath: "/nonexistent-\(UUID().uuidString)")
        #expect(FileTreeLoader.contents(of: bogus).isEmpty)
    }
}

// MARK: - FileNode

@MainActor
@Suite struct FileNodeTests {
    @Test func fileNodeNeverLoadsChildren() async throws {
        try await TestSupport.withTempDir { dir in
            let file = dir.appending(path: "f.txt")
            FileManager.default.createFile(atPath: file.path, contents: Data())
            let node = FileNode(url: file, isDirectory: false)
            await node.loadChildren()
            #expect(node.children == nil)
            #expect(node.isLoaded == false)
        }
    }

    @Test func loadChildrenLoadsOnceUnlessReloading() async throws {
        try await TestSupport.withTempDir { dir in
            let fm = FileManager.default
            fm.createFile(atPath: dir.appending(path: "a.txt").path, contents: Data())
            let node = FileNode(url: dir, isDirectory: true)
            await node.loadChildren()
            #expect(node.isLoaded)
            #expect(node.children?.map(\.name) == ["a.txt"])

            // A second plain load is a no-op even after the directory changed…
            fm.createFile(atPath: dir.appending(path: "b.txt").path, contents: Data())
            await node.loadChildren()
            #expect(node.children?.count == 1)

            // …but an explicit reload re-reads.
            await node.loadChildren(reload: true)
            #expect(node.children?.count == 2)
        }
    }

    @Test func loadChildrenSyncIfNeededLoadsAndIsIdempotent() throws {
        try TestSupport.withTempDir { dir in
            FileManager.default.createFile(atPath: dir.appending(path: "x.txt").path, contents: Data())
            let node = FileNode(url: dir, isDirectory: true)
            node.loadChildrenSyncIfNeeded()
            #expect(node.isLoaded)
            let first = node.children?.first
            node.loadChildrenSyncIfNeeded()
            // Same child instances: no reload happened.
            #expect(node.children?.first === first)
        }
    }

    @Test func reloadMergingKeepsSurvivingNodesAndTheirState() async throws {
        try await TestSupport.withTempDir { dir in
            let fm = FileManager.default
            let keptDir = dir.appending(path: "kept")
            try fm.createDirectory(at: keptDir, withIntermediateDirectories: false)
            fm.createFile(atPath: dir.appending(path: "doomed.txt").path, contents: Data())

            let node = FileNode(url: dir, isDirectory: true)
            await node.loadChildren()
            let kept = try #require(node.children?.first { $0.name == "kept" })
            kept.isExpanded = true

            try fm.removeItem(at: dir.appending(path: "doomed.txt"))
            fm.createFile(atPath: dir.appending(path: "new.txt").path, contents: Data())
            await node.reloadChildrenMerging()

            let names = node.children?.map(\.name) ?? []
            #expect(names.contains("kept"))
            #expect(names.contains("new.txt"))
            #expect(!names.contains("doomed.txt"))
            // The surviving node is the *same instance*, expansion preserved.
            let keptAfter = node.children?.first { $0.name == "kept" }
            #expect(keptAfter === kept)
            #expect(keptAfter?.isExpanded == true)
        }
    }

    @Test func reloadMergingBeforeLoadIsNoOp() async throws {
        try await TestSupport.withTempDir { dir in
            let node = FileNode(url: dir, isDirectory: true)
            await node.reloadChildrenMerging()
            #expect(node.children == nil)
            #expect(node.isLoaded == false)
        }
    }
}

// MARK: - FileOperations

@Suite struct FileOperationsTests {
    @Test func renameMovesTheFile() throws {
        try TestSupport.withTempDir { dir in
            let original = dir.appending(path: "old.txt")
            try "hi".write(to: original, atomically: true, encoding: .utf8)
            let renamed = try FileOperations.rename(original, to: "new.txt")
            #expect(renamed.lastPathComponent == "new.txt")
            #expect(!FileManager.default.fileExists(atPath: original.path))
            #expect(try String(contentsOf: renamed, encoding: .utf8) == "hi")
        }
    }

    @Test func renameTrimsWhitespace() throws {
        try TestSupport.withTempDir { dir in
            let original = dir.appending(path: "a.txt")
            FileManager.default.createFile(atPath: original.path, contents: Data())
            let renamed = try FileOperations.rename(original, to: "  b.txt  ")
            #expect(renamed.lastPathComponent == "b.txt")
        }
    }

    @Test func renameToSameOrEmptyNameIsNoOp() throws {
        try TestSupport.withTempDir { dir in
            let original = dir.appending(path: "same.txt")
            FileManager.default.createFile(atPath: original.path, contents: Data())
            let sameName = try FileOperations.rename(original, to: "same.txt")
            #expect(sameName == original)
            let blankName = try FileOperations.rename(original, to: "   ")
            #expect(blankName == original)
        }
    }

    @Test(arguments: ["a/b", "../escape", ".", ".."])
    func renameRejectsPathTraversal(name: String) throws {
        try TestSupport.withTempDir { dir in
            let original = dir.appending(path: "victim.txt")
            FileManager.default.createFile(atPath: original.path, contents: Data())
            #expect(throws: FileOperations.RenameError.self) {
                try FileOperations.rename(original, to: name)
            }
            // Nothing moved.
            #expect(FileManager.default.fileExists(atPath: original.path))
        }
    }

    @Test func uniqueURLReturnsBaseWhenFree() throws {
        try TestSupport.withTempDir { dir in
            #expect(FileOperations.uniqueURL(in: dir, baseName: "fresh.txt").lastPathComponent == "fresh.txt")
        }
    }

    @Test func uniqueURLAppendsCounterBeforeExtension() throws {
        try TestSupport.withTempDir { dir in
            let fm = FileManager.default
            fm.createFile(atPath: dir.appending(path: "note.txt").path, contents: Data())
            fm.createFile(atPath: dir.appending(path: "note 2.txt").path, contents: Data())
            #expect(FileOperations.uniqueURL(in: dir, baseName: "note.txt").lastPathComponent == "note 3.txt")
        }
    }

    @Test func uniqueURLHandlesExtensionlessNames() throws {
        try TestSupport.withTempDir { dir in
            try FileManager.default.createDirectory(
                at: dir.appending(path: "untitled folder"), withIntermediateDirectories: false
            )
            #expect(
                FileOperations.uniqueURL(in: dir, baseName: "untitled folder").lastPathComponent
                    == "untitled folder 2"
            )
        }
    }

    @Test func uniqueURLTreatsDanglingSymlinkAsOccupied() throws {
        try TestSupport.withTempDir { dir in
            try FileManager.default.createSymbolicLink(
                at: dir.appending(path: "taken.txt"),
                withDestinationURL: dir.appending(path: "nowhere")
            )
            // `fileExists` would report the broken link as absent; uniqueURL must not.
            #expect(FileOperations.uniqueURL(in: dir, baseName: "taken.txt").lastPathComponent == "taken 2.txt")
        }
    }

    @MainActor
    @Test func copyToPasteboardPutsTheString() {
        // Snapshot and restore the user's clipboard around the assertion.
        let pasteboard = NSPasteboard.general
        let prior = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let prior { pasteboard.setString(prior, forType: .string) }
        }
        FileOperations.copyToPasteboard("/copied/path.txt")
        #expect(pasteboard.string(forType: .string) == "/copied/path.txt")
    }

    @Test func createFileAndFolderPickUniqueNames() throws {
        try TestSupport.withTempDir { dir in
            let first = try FileOperations.createFile(in: dir)
            let second = try FileOperations.createFile(in: dir)
            #expect(first.lastPathComponent == "untitled")
            #expect(second.lastPathComponent == "untitled 2")
            #expect(FileManager.default.fileExists(atPath: second.path))

            let folder = try FileOperations.createFolder(in: dir)
            #expect(folder.lastPathComponent == "untitled folder")
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }
}

// MARK: - FileSystemWatcher

@MainActor
@Suite struct FileSystemWatcherTests {
    @Test func reportsChangesUnderTheWatchedRoot() async throws {
        try await TestSupport.withTempDir { dir in
            // FSEvents delivers realpath'd paths, and Foundation's symlink
            // resolution strips /private — canonicalize both sides the same way
            // so the comparison can't miss on spelling.
            let canonicalRoot = dir.resolvingSymlinksInPath().path

            let hits = LockedBox<[String]>(initialState: [])
            let watcher = FileSystemWatcher(path: dir.path(percentEncoded: false)) { paths in
                hits.withLock { $0.append(contentsOf: paths) }
            }
            #expect(watcher != nil)

            // Give the stream a beat to start, then touch the directory.
            try await Task.sleep(for: .milliseconds(200))
            FileManager.default.createFile(atPath: dir.appending(path: "trigger.txt").path, contents: Data())

            let sawEvent = await TestSupport.waitUntil(timeout: 10) {
                hits.withLock { paths in
                    paths.contains {
                        URL(filePath: $0).resolvingSymlinksInPath().path.hasPrefix(canonicalRoot)
                    }
                }
            }
            #expect(sawEvent, "expected an FSEvents callback for the watched directory")
            _ = watcher // keep alive until here
        }
    }
}

/// Tiny Sendable lock box for cross-queue assertions in watcher tests.
private final class LockedBox<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()
    init(initialState: State) { self.state = initialState }
    func withLock<R>(_ body: (inout State) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&state)
    }
}
