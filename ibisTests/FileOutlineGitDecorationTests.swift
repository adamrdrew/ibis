import Testing
import AppKit
import SwiftUI
@testable import Ibis

/// The file browser's Git decoration: badge letters and name tints on real cells,
/// driven by a real repository. Complements `GitStatusFileStateTests` (which
/// parses canned porcelain) by covering the seam between the model's absolute
/// paths and the tree's `FileNode` URLs — the part that silently decorates
/// nothing if the two spellings drift apart.
/// Serialized: workspaces touch shared UserDefaults keys (trust, layout).
@MainActor
@Suite(.serialized) struct FileOutlineGitDecorationTests {
    /// Builds a committed repo in a temp dir, then a workspace + coordinator-wired
    /// outline view over it (mirroring `makeNSView`, including Git observation).
    private func withRepoTree(
        ignoring ignoreRules: String? = nil,
        _ body: (Workspace, URL, FileOutlineView.Coordinator, TreeOutlineView) async throws -> Void
    ) async throws {
        try await TestSupport.withIsolatedDefaults {
            try await TestSupport.withTempDir { dir in
                try git(["init", "-q", "-b", "main"], in: dir)
                try write("one\n", to: dir.appending(path: "tracked.swift"))
                try write("two\n", to: dir.appending(path: "other.swift"))
                // Written before the workspace opens: the ignore set is probed on
                // the first refresh and then only every few seconds, so this is
                // also the realistic case (a repo whose .gitignore predates you).
                if let ignoreRules {
                    try write(ignoreRules, to: dir.appending(path: ".gitignore"))
                }
                try git(["add", "-A"], in: dir)
                try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], in: dir)

                let workspace = Workspace(rootURL: dir, isDirectory: true)
                let coordinator = FileOutlineView.Coordinator(
                    workspace: workspace,
                    selection: .constant(nil)
                )
                let outlineView = TreeOutlineView()
                outlineView.headerView = nil
                // A real frame, so AppKit instantiates row views — the
                // decoration path has nothing to update without them.
                outlineView.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
                let column = NSTableColumn(identifier: .init("name"))
                outlineView.addTableColumn(column)
                outlineView.outlineTableColumn = column
                outlineView.dataSource = coordinator
                outlineView.delegate = coordinator
                outlineView.coordinator = coordinator
                coordinator.outlineView = outlineView
                coordinator.installReloadBridge()
                coordinator.observeGitStatus()
                outlineView.reloadData()
                try await body(workspace, dir, coordinator, outlineView)
            }
        }
    }

    private func git(_ arguments: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path(percentEncoded: false)] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The badge letter currently shown for a row, or nil if there's no row.
    private func badge(for name: String, in outlineView: NSOutlineView) -> String? {
        cell(for: name, in: outlineView)?.badge?.stringValue
    }

    private func nameColor(for name: String, in outlineView: NSOutlineView) -> NSColor? {
        cell(for: name, in: outlineView)?.textField?.textColor
    }

    private func iconColor(for name: String, in outlineView: NSOutlineView) -> NSColor? {
        cell(for: name, in: outlineView)?.imageView?.contentTintColor
    }

    private func cell(for name: String, in outlineView: NSOutlineView) -> FileCellView? {
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileNode, node.name == name else { continue }
            return outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView
        }
        return nil
    }

    /// Waits for the workspace's Git probe to report `path`'s state.
    private func waitForChange(
        _ change: GitStatusModel.FileChange?,
        at url: URL,
        in workspace: Workspace
    ) async -> Bool {
        await TestSupport.waitUntil {
            workspace.git.info.change(at: url.path(percentEncoded: false)) == change
        }
    }

    @Test func modifiedFileIsBadgedAndTinted() async throws {
        try await withRepoTree { workspace, dir, _, outlineView in
            let tracked = dir.appending(path: "tracked.swift")
            try write("one\nedited\n", to: tracked)
            workspace.git.refresh()
            #expect(await waitForChange(.modified, at: tracked, in: workspace))

            outlineView.reloadData()
            #expect(badge(for: "tracked.swift", in: outlineView) == "M")
            #expect(nameColor(for: "tracked.swift", in: outlineView) == .systemOrange)
            // The committed, unchanged sibling stays undecorated.
            #expect(badge(for: "other.swift", in: outlineView) == "")
            #expect(nameColor(for: "other.swift", in: outlineView) == .labelColor)
        }
    }

    @Test func untrackedFileIsBadged() async throws {
        try await withRepoTree { workspace, dir, _, outlineView in
            let scratch = dir.appending(path: "scratch.txt")
            try write("new\n", to: scratch)
            workspace.git.refresh()
            #expect(await waitForChange(.untracked, at: scratch, in: workspace))

            await workspace.reloadDirectory(at: dir)
            #expect(badge(for: "scratch.txt", in: outlineView) == "U")
            #expect(nameColor(for: "scratch.txt", in: outlineView) == .systemGreen)
        }
    }

    @Test func folderWithChangesInsideGetsARollUpDot() async throws {
        try await withRepoTree { workspace, dir, _, outlineView in
            let nested = dir.appending(path: "nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let inside = nested.appending(path: "inside.txt")
            try write("new\n", to: inside)
            workspace.git.refresh()
            #expect(await waitForChange(.untracked, at: inside, in: workspace))

            await workspace.reloadDirectory(at: dir)
            // The folder is untracked itself here, so it carries the file's own
            // badge; the roll-up dot is what a *tracked* folder gets.
            #expect(badge(for: "nested", in: outlineView) == "U")

            try git(["add", "nested"], in: dir)
            try write("edited\n", to: inside)
            workspace.git.refresh()
            #expect(await waitForChange(.modified, at: inside, in: workspace))
            #expect(workspace.git.info.directoryHasChanges(at: nested.path(percentEncoded: false)))

            outlineView.reloadData()
            #expect(badge(for: "nested", in: outlineView) == "•")
        }
    }

    /// The badge has to follow Git state on its own — a commit or a stage made
    /// in the integrated terminal never reloads the tree, so nothing else would
    /// repaint the row.
    @Test func badgesUpdateWithoutAReload() async throws {
        try await withRepoTree { workspace, dir, _, outlineView in
            let tracked = dir.appending(path: "tracked.swift")
            try write("one\nedited\n", to: tracked)
            workspace.git.refresh()
            #expect(await waitForChange(.modified, at: tracked, in: workspace))
            outlineView.reloadData()
            #expect(badge(for: "tracked.swift", in: outlineView) == "M")

            // Undo the edit behind the app's back — no file added or removed, so
            // no tree reload happens.
            try write("one\n", to: tracked)
            workspace.git.refresh()
            #expect(await waitForChange(nil, at: tracked, in: workspace))

            #expect(await TestSupport.waitUntil {
                badge(for: "tracked.swift", in: outlineView) == ""
            })
            #expect(nameColor(for: "tracked.swift", in: outlineView) == .labelColor)
        }
    }

    /// Ignored paths fade instead of being badged — a `node_modules` subtree
    /// would otherwise shout louder than the handful of real changes.
    @Test func ignoredPathsAreDimmedNotBadged() async throws {
        try await withRepoTree(ignoring: "junk/\n") { workspace, dir, _, outlineView in
            let junk = dir.appending(path: "junk")
            try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
            try write("noise\n", to: junk.appending(path: "output.log"))
            workspace.git.refresh()

            #expect(await TestSupport.waitUntil {
                workspace.git.info.isIgnored(at: junk.path(percentEncoded: false))
            })
            // Inherited from the collapsed folder entry, which is all git prints.
            #expect(workspace.git.info.isIgnored(at: junk.appending(path: "output.log").path(percentEncoded: false)))
            // Ignored is not dirty: no badge, and no roll-up dot on its parent.
            #expect(workspace.git.info.directoryHasChanges(at: junk.path(percentEncoded: false)) == false)

            await workspace.reloadDirectory(at: dir)
            #expect(badge(for: "junk", in: outlineView) == "")
            #expect(nameColor(for: "junk", in: outlineView) == .tertiaryLabelColor)
            #expect(iconColor(for: "junk", in: outlineView) == .tertiaryLabelColor)
            // A committed, unignored sibling keeps the normal treatment.
            #expect(nameColor(for: "tracked.swift", in: outlineView) == .labelColor)
            #expect(iconColor(for: "tracked.swift", in: outlineView) == .secondaryLabelColor)
        }
    }

    /// The ignore set is probed on a slow cadence, so a cheap refresh in between
    /// must carry it forward — otherwise dimmed rows blink back to normal every
    /// time anything on disk changes.
    @Test func dimmingSurvivesRefreshesThatSkipTheIgnoreProbe() async throws {
        try await withRepoTree(ignoring: "junk/\n") { workspace, dir, _, outlineView in
            let junk = dir.appending(path: "junk")
            try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
            try write("noise\n", to: junk.appending(path: "output.log"))
            workspace.git.refresh()
            #expect(await TestSupport.waitUntil {
                workspace.git.info.isIgnored(at: junk.path(percentEncoded: false))
            })

            // An ordinary edit lands moments later: too soon for another ignore
            // probe, so this refresh runs without `--ignored`.
            try write("one\nedited\n", to: dir.appending(path: "tracked.swift"))
            workspace.git.refresh()
            #expect(await waitForChange(.modified, at: dir.appending(path: "tracked.swift"), in: workspace))

            #expect(workspace.git.info.isIgnored(at: junk.path(percentEncoded: false)))
            await workspace.reloadDirectory(at: dir)
            #expect(nameColor(for: "junk", in: outlineView) == .tertiaryLabelColor)
        }
    }

    @Test func nothingIsDecoratedOutsideARepository() async throws {
        try await TestSupport.withIsolatedDefaults {
            try await TestSupport.withTempDir { dir in
                try write("hello\n", to: dir.appending(path: "loose.txt"))
                let workspace = Workspace(rootURL: dir, isDirectory: true)
                let coordinator = FileOutlineView.Coordinator(
                    workspace: workspace,
                    selection: .constant(nil)
                )
                let outlineView = TreeOutlineView()
                outlineView.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
                let column = NSTableColumn(identifier: .init("name"))
                outlineView.addTableColumn(column)
                outlineView.outlineTableColumn = column
                outlineView.dataSource = coordinator
                outlineView.delegate = coordinator
                outlineView.coordinator = coordinator
                coordinator.outlineView = outlineView
                outlineView.reloadData()

                #expect(await TestSupport.waitUntil {
                    workspace.git.info.isRepository == false && outlineView.numberOfRows == 1
                })
                #expect(badge(for: "loose.txt", in: outlineView) == "")
                #expect(nameColor(for: "loose.txt", in: outlineView) == .labelColor)
            }
        }
    }
}
