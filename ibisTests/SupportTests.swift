import Testing
import Foundation
import SwiftUI
import AppKit
@testable import Ibis

// MARK: - WorkspaceRef

@Suite struct WorkspaceRefTests {
    @Test func canonicalStripsTrailingSlash() {
        #expect(WorkspaceRef.canonical("/Users/nobody/proj/") == "/Users/nobody/proj")
        // Root itself keeps its single slash.
        #expect(WorkspaceRef.canonical("/") == "/")
    }

    @Test func canonicalResolvesSymlinks() {
        // /tmp and /private/tmp are the same folder on macOS; both spellings
        // must canonicalize identically (Foundation strips the /private prefix,
        // so the shared form is "/tmp" — but the contract is the equivalence).
        #expect(WorkspaceRef.canonical("/tmp") == WorkspaceRef.canonical("/private/tmp"))
    }

    @Test func equalityAndHashingKeyOffTheCanonicalPath() {
        let viaTmp = WorkspaceRef(path: "/tmp", isDirectory: true)
        let viaPrivate = WorkspaceRef(path: "/private/tmp/", isDirectory: true)
        #expect(viaTmp == viaPrivate)
        #expect(viaTmp.hashValue == viaPrivate.hashValue)
        #expect(viaTmp.id == viaPrivate.id)
    }

    @Test func urlInitPreservesThePath() {
        let ref = WorkspaceRef(url: URL(filePath: "/some/folder"), isDirectory: true)
        #expect(ref.path == "/some/folder")
        #expect(ref.url == URL(filePath: "/some/folder"))
    }

    @Test func codableRoundTrip() throws {
        let ref = WorkspaceRef(path: "/a/b", isDirectory: false)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(WorkspaceRef.self, from: data)
        #expect(decoded == ref)
        #expect(decoded.isDirectory == false)
    }
}

// MARK: - LaunchRouter

/// The router is a process-wide singleton the live app UI also observes, so
/// each test drains it synchronously (no awaits between enqueue and drain).
@MainActor
@Suite(.serialized) struct LaunchRouterTests {
    @Test func enqueueThenDrainReturnsAndClears() {
        _ = LaunchRouter.shared.drain() // start clean
        let ref = WorkspaceRef(path: "/tmp/router-test", isDirectory: true)
        LaunchRouter.shared.enqueue(ref)
        #expect(LaunchRouter.shared.pendingCount == 1)
        let drained = LaunchRouter.shared.drain()
        #expect(drained == [ref])
        #expect(LaunchRouter.shared.pendingCount == 0)
        #expect(LaunchRouter.shared.drain().isEmpty)
    }

    @Test func agentLaunchIsConsumedExactlyOnce() {
        _ = LaunchRouter.shared.drain()
        let url = URL(filePath: "/tmp/agent-launch-test")
        let ref = WorkspaceRef(url: url, isDirectory: true)
        let signalBefore = LaunchRouter.shared.agentLaunchSignal
        LaunchRouter.shared.enqueue(ref, runAgent: true)
        _ = LaunchRouter.shared.drain()
        #expect(LaunchRouter.shared.agentLaunchSignal != signalBefore)
        #expect(LaunchRouter.shared.consumeAgentLaunch(for: url))
        #expect(LaunchRouter.shared.consumeAgentLaunch(for: url) == false)
    }

    @Test func agentLaunchMatchesCanonicalSpellings() throws {
        _ = LaunchRouter.shared.drain()
        // Enqueued via /tmp, consumed via /private/tmp — one canonical root.
        // The folder must exist: symlink resolution only collapses the two
        // spellings for paths that are actually on disk.
        let name = "agent-canon-\(UUID().uuidString)"
        let viaTmp = URL(filePath: "/tmp/\(name)")
        try FileManager.default.createDirectory(at: viaTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: viaTmp) }

        LaunchRouter.shared.enqueue(WorkspaceRef(url: viaTmp, isDirectory: true), runAgent: true)
        _ = LaunchRouter.shared.drain()
        #expect(LaunchRouter.shared.consumeAgentLaunch(for: URL(filePath: "/private/tmp/\(name)")))
    }

    @Test func plainEnqueueRequestsNoAgentLaunch() {
        _ = LaunchRouter.shared.drain()
        let url = URL(filePath: "/tmp/no-agent-test")
        LaunchRouter.shared.enqueue(WorkspaceRef(url: url, isDirectory: true))
        _ = LaunchRouter.shared.drain()
        #expect(LaunchRouter.shared.consumeAgentLaunch(for: url) == false)
    }
}

// MARK: - FileIconProvider

@Suite struct FileIconProviderTests {
    private func node(_ path: String, isDirectory: Bool) -> FileNode {
        FileNode(url: URL(filePath: path), isDirectory: isDirectory)
    }

    @Test(arguments: [
        ("/p/.git", "folder.badge.gearshape"),
        ("/p/.github", "folder.badge.gearshape"),
        ("/p/node_modules", "shippingbox"),
        ("/p/build", "shippingbox"),
        ("/p/Sources", "folder"),
    ])
    func folderSymbols(path: String, expected: String) {
        #expect(FileIconProvider.symbolName(for: node(path, isDirectory: true)) == expected)
    }

    @Test(arguments: [
        ("/p/Package.swift", "swift"),
        ("/p/Dockerfile", "shippingbox"),
        ("/p/Makefile", "hammer"),
        ("/p/README.md", "book"),
        ("/p/LICENSE", "checkmark.seal"),
        ("/p/.gitignore", "eye.slash"),
        ("/p/main.swift", "swift"),
        ("/p/app.ts", "curlybraces"),
        ("/p/data.json", "curlybraces.square"),
        ("/p/index.html", "chevron.left.forwardslash.chevron.right"),
        ("/p/style.css", "paintbrush"),
        ("/p/notes.md", "doc.richtext"),
        ("/p/run.sh", "terminal"),
        ("/p/config.yaml", "gearshape"),
        ("/p/Cargo.lock", "lock"),
        ("/p/photo.png", "photo"),
        ("/p/archive.zip", "archivebox"),
        ("/p/song.mp3", "music.note"),
        ("/p/movie.mp4", "film"),
        ("/p/font.ttf", "textformat"),
        ("/p/app.db", "cylinder.split.1x2"),
        ("/p/data.csv", "tablecells"),
        ("/p/mystery.xyz", "doc"),
    ])
    func fileSymbols(path: String, expected: String) {
        #expect(FileIconProvider.symbolName(for: node(path, isDirectory: false)) == expected)
        #expect(FileIconProvider.symbolName(forFileURL: URL(filePath: path)) == expected)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(FileIconProvider.symbolName(forFileURL: URL(filePath: "/p/README.MD")) == "book")
        #expect(FileIconProvider.symbolName(forFileURL: URL(filePath: "/p/MAIN.SWIFT")) == "swift")
    }

    @Test func foldersGetTheAccentTint() {
        #expect(FileIconProvider.tint(for: node("/p/dir", isDirectory: true)) == .ibisAccent)
        #expect(FileIconProvider.tint(for: node("/p/f.txt", isDirectory: false)) == .secondary)
    }
}

// MARK: - EditorTheme & color plumbing

@Suite struct EditorThemeTests {
    @Test func themeNameTracksAppearance() {
        #expect(EditorTheme.name(isDark: false) == EditorTheme.light)
        #expect(EditorTheme.name(isDark: true) == EditorTheme.dark)
    }

    @Test func rgbaComponentsRoundTrip() {
        let color = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        let rgba = color.rgbaComponents
        #expect(abs(rgba.red - 0.25) < 0.001)
        #expect(abs(rgba.green - 0.5) < 0.001)
        #expect(abs(rgba.blue - 0.75) < 0.001)
        #expect(rgba.alpha == 1)
        // And back to NSColor.
        #expect(abs(rgba.nsColor.redComponent - 0.25) < 0.001)
    }
}
