import Testing
import Foundation
@testable import ibis

/// Exercises the `Workspace` model headlessly: document caching, rename/move
/// re-pointing, layout persistence, navigation, and the agent-edit review flow.
/// Alert/sheet paths that require a window are exercised only via their
/// no-window fallbacks. Serialized: workspaces touch shared UserDefaults keys
/// (trust, layout snapshots, MCP tokens).
@MainActor
@Suite(.serialized) struct WorkspaceTests {
    private static let preservedKeys = [
        "workspaceState.v1", "workspace.trust.v1", "mcp.projectTokens.v1",
    ]

    /// Builds a folder workspace over a fresh temp dir and runs `body`.
    private func withWorkspace<T>(
        _ body: (Workspace, URL) async throws -> T
    ) async throws -> T {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let workspace = Workspace(rootURL: dir, isDirectory: true)
                return try await body(workspace, dir)
            }
        }
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Basics

    @Test func displayNameIsRootFolderName() async throws {
        try await withWorkspace { workspace, dir in
            #expect(workspace.displayName == dir.lastPathComponent)
        }
    }

    @Test func singleFileWorkspaceUsesParentAsProjectRoot() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let file = try writeFile("solo.txt", "x", in: dir)
                let workspace = Workspace(rootURL: file, isDirectory: false)
                #expect(workspace.projectRoot.resolvingSymlinksInPath().path
                    == dir.resolvingSymlinksInPath().path)
                #expect(workspace.terminal.workingDirectory == workspace.projectRoot)
            }
        }
    }

    @Test func workspaceRegistersInLiveRegistry() async throws {
        try await withWorkspace { workspace, _ in
            #expect(Workspace.all.contains { $0 === workspace })
        }
    }

    // MARK: Document cache

    @Test func documentForURLIsCachedAndReused() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("a.txt", "hello", in: dir)
            #expect(workspace.openedDocument(for: url) == nil)
            let doc = workspace.document(for: url)
            #expect(workspace.document(for: url) === doc)
            #expect(workspace.openedDocument(for: url) === doc)
        }
    }

    @Test func cacheCollapsesSymlinkSpellingsOfTheSameFile() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            // /tmp is a symlink to /private/tmp on macOS — the classic two
            // spellings of one file.
            let name = "ibis-symlink-test-\(UUID().uuidString)"
            let viaTmp = URL(filePath: "/tmp/\(name)")
            let viaPrivate = URL(filePath: "/private/tmp/\(name)")
            try FileManager.default.createDirectory(at: viaTmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: viaPrivate) }
            try "same".write(to: viaTmp.appending(path: "f.txt"), atomically: true, encoding: .utf8)

            let workspace = Workspace(rootURL: viaTmp, isDirectory: true)
            let a = workspace.document(for: viaTmp.appending(path: "f.txt"))
            let b = workspace.document(for: viaPrivate.appending(path: "f.txt"))
            #expect(a === b)
        }
    }

    @Test func relocateRepointsAMovedFile() async throws {
        try await withWorkspace { workspace, dir in
            let old = try writeFile("before.txt", "content", in: dir)
            let doc = workspace.document(for: old)
            await doc.loadIfNeeded()

            let new = dir.appending(path: "after.txt")
            try FileManager.default.moveItem(at: old, to: new)
            workspace.relocateOpenDocuments(from: old, to: new)

            #expect(doc.url?.lastPathComponent == "after.txt")
            #expect(workspace.openedDocument(for: new) === doc)
            #expect(workspace.openedDocument(for: old) == nil)
        }
    }

    @Test func relocateRepointsDescendantsOfAMovedDirectory() async throws {
        try await withWorkspace { workspace, dir in
            let fm = FileManager.default
            let oldDir = dir.appending(path: "pkg")
            try fm.createDirectory(at: oldDir.appending(path: "sub"), withIntermediateDirectories: true)
            let nested = try writeFile("pkg/sub/deep.txt", "x", in: dir)
            let doc = workspace.document(for: nested)

            let newDir = dir.appending(path: "renamed-pkg")
            try fm.moveItem(at: oldDir, to: newDir)
            workspace.relocateOpenDocuments(from: oldDir, to: newDir)

            #expect(doc.url?.path(percentEncoded: false).contains("renamed-pkg/sub/deep.txt") == true)
            #expect(workspace.openedDocument(for: newDir.appending(path: "sub/deep.txt")) === doc)
        }
    }

    // MARK: Navigation

    @Test func goToLineSelectsTheRequestedLine() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("lines.txt", "one\ntwo\nthree", in: dir)
            let doc = workspace.document(for: url)
            await doc.loadIfNeeded()
            workspace.layout.activePane?.open(doc)

            workspace.goToLine(2)
            let ns = doc.text as NSString
            #expect(doc.pendingSelection == ns.range(of: "two\n"))
        }
    }

    @Test func goToLineClampsBeyondEndToLastLine() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("lines.txt", "one\ntwo", in: dir)
            let doc = workspace.document(for: url)
            await doc.loadIfNeeded()
            workspace.layout.activePane?.open(doc)

            workspace.goToLine(99)
            let ns = doc.text as NSString
            #expect(doc.pendingSelection == ns.range(of: "two"))
        }
    }

    @Test func goToLineOnEmptyDocumentSelectsZeroRange() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("empty.txt", "", in: dir)
            let doc = workspace.document(for: url)
            await doc.loadIfNeeded()
            workspace.layout.activePane?.open(doc)
            workspace.goToLine(3)
            #expect(doc.pendingSelection == NSRange(location: 0, length: 0))
        }
    }

    @Test func selectAdjacentTabWrapsBothWays() async throws {
        try await withWorkspace { workspace, _ in
            let pane = try #require(workspace.layout.activePane)
            let a = OpenDocument(); let b = OpenDocument(); let c = OpenDocument()
            pane.open(a); pane.open(b); pane.open(c)
            pane.selectedID = c.id
            workspace.selectAdjacentTab(offset: 1)
            #expect(pane.selectedID == a.id) // wrapped forward
            workspace.selectAdjacentTab(offset: -1)
            #expect(pane.selectedID == c.id) // wrapped back
        }
    }

    @Test func newUntitledDocumentOpensInActivePane() async throws {
        try await withWorkspace { workspace, _ in
            workspace.newUntitledDocument()
            #expect(workspace.activeDocument?.isUntitled == true)
        }
    }

    // MARK: Dirty tracking & tab closing

    @Test func dirtyDocumentsAreDistinctAcrossPanes() async throws {
        try await withWorkspace { workspace, _ in
            let doc = OpenDocument()
            doc.isDirty = true
            workspace.layout.activePane?.open(doc)
            workspace.splitActiveEditor() // same document now in two panes
            #expect(workspace.layout.panes.count == 2)
            #expect(workspace.dirtyDocuments.count == 1)
        }
    }

    @Test func closingCleanTabJustCloses() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("clean.txt", "x", in: dir)
            let doc = workspace.document(for: url)
            await doc.loadIfNeeded()
            let pane = try #require(workspace.layout.activePane)
            pane.open(doc)
            workspace.requestCloseTab(doc, in: pane)
            #expect(pane.tabDocuments.isEmpty)
        }
    }

    @Test func closingDirtyTabStillOpenElsewhereSkipsThePrompt() async throws {
        try await withWorkspace { workspace, _ in
            let doc = OpenDocument()
            doc.isDirty = true
            let pane = try #require(workspace.layout.activePane)
            pane.open(doc)
            workspace.splitActiveEditor()
            let second = try #require(workspace.layout.activePane)
            #expect(second !== pane)

            // Closing in the second pane must not prompt (still open in the first)
            // and, since the second pane empties, the pane itself closes.
            workspace.requestCloseTab(doc, in: second)
            #expect(workspace.layout.panes.count == 1)
            #expect(pane.tabDocuments.contains { $0.id == doc.id })
        }
    }

    @Test func requestClosePaneRefusesToCloseTheLastPane() async throws {
        try await withWorkspace { workspace, _ in
            let pane = try #require(workspace.layout.activePane)
            workspace.requestClosePane(pane)
            #expect(workspace.layout.panes.count == 1)
        }
    }

    @Test func windowCloseIsAllowedWhenNothingIsDirty() async throws {
        try await withWorkspace { workspace, _ in
            workspace.layout.activePane?.open(OpenDocument())
            #expect(workspace.requestWindowClose(proceed: {}) == true)
        }
    }

    // MARK: Layout persistence

    @Test func layoutFingerprintTracksTabsAndSelection() async throws {
        try await withWorkspace { workspace, dir in
            let before = workspace.layoutFingerprint
            let url = try writeFile("fp.txt", "x", in: dir)
            let doc = workspace.document(for: url)
            await doc.loadIfNeeded()
            workspace.layout.activePane?.open(doc)
            let afterOpen = workspace.layoutFingerprint
            #expect(afterOpen != before)
            workspace.splitActiveEditor()
            #expect(workspace.layoutFingerprint != afterOpen)
        }
    }

    @Test func persistedLayoutRestoresTabsPanesAndSelection() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let first = Workspace(rootURL: dir, isDirectory: true)
                let urlA = dir.appending(path: "a.txt")
                let urlB = dir.appending(path: "b.txt")
                try "aaa".write(to: urlA, atomically: true, encoding: .utf8)
                try "bbb".write(to: urlB, atomically: true, encoding: .utf8)
                let docA = first.document(for: urlA)
                let docB = first.document(for: urlB)
                await docA.loadIfNeeded()
                await docB.loadIfNeeded()
                let pane = try #require(first.layout.activePane)
                pane.open(docA)
                pane.open(docB)
                pane.selectedID = docA.id
                first.persistLayoutState()

                // A fresh workspace over the same root restores the layout.
                let second = Workspace(rootURL: dir, isDirectory: true)
                await second.restorePersistedLayout()
                let restored = try #require(second.layout.activePane)
                #expect(restored.tabDocuments.map { $0.url?.lastPathComponent } == ["a.txt", "b.txt"])
                #expect(restored.selectedDocument?.url?.lastPathComponent == "a.txt")
            }
        }
    }

    @Test func restoreSkipsMissingFilesAndResolvesSelectionByPath() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let survivor = dir.appending(path: "survivor.txt")
                try "s".write(to: survivor, atomically: true, encoding: .utf8)
                // Persist a layout that references a file that no longer exists,
                // with the selection index pointing at the survivor.
                let state = PersistedWorkspaceState(
                    paneFilePaths: [[
                        dir.appending(path: "gone.txt").path(percentEncoded: false),
                        survivor.path(percentEncoded: false),
                    ]],
                    selectedTabPerPane: [1],
                    activePaneIndex: 0,
                    savedAt: Date()
                )
                WorkspaceStateStore.save(state, for: dir)

                let workspace = Workspace(rootURL: dir, isDirectory: true)
                await workspace.restorePersistedLayout()
                let pane = try #require(workspace.layout.activePane)
                #expect(pane.tabDocuments.map { $0.url?.lastPathComponent } == ["survivor.txt"])
                #expect(pane.selectedDocument?.url?.lastPathComponent == "survivor.txt")
            }
        }
    }

    @Test func restoreDoesNothingWhenTabsAreAlreadyOpen() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let url = dir.appending(path: "x.txt")
                try "x".write(to: url, atomically: true, encoding: .utf8)
                let state = PersistedWorkspaceState(
                    paneFilePaths: [[url.path(percentEncoded: false)]],
                    selectedTabPerPane: [0],
                    activePaneIndex: 0,
                    savedAt: Date()
                )
                WorkspaceStateStore.save(state, for: dir)

                let workspace = Workspace(rootURL: dir, isDirectory: true)
                workspace.layout.activePane?.open(OpenDocument()) // user already opened something
                await workspace.restorePersistedLayout()
                #expect(workspace.layout.activePane?.tabDocuments.count == 1)
                #expect(workspace.layout.activePane?.selectedDocument?.isUntitled == true)
            }
        }
    }

    // MARK: Agent diff review

    @Test func diffDecisionResolvesApplyAndDecline() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("d.txt", "old", in: dir)
            let proposal = try #require(LineDiff.proposal(fileURL: url, before: "old", after: "new"))

            async let decision = workspace.awaitDiffDecision(proposal)
            let presented = await TestSupport.waitUntil { workspace.pendingDiff != nil }
            #expect(presented)
            workspace.resolvePendingDiff(apply: true)
            #expect(await decision == true)
            #expect(workspace.pendingDiff == nil)
        }
    }

    @Test func secondDiffRequestDeclinesTheFirst() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("d.txt", "old", in: dir)
            let p1 = try #require(LineDiff.proposal(fileURL: url, before: "old", after: "one"))
            let p2 = try #require(LineDiff.proposal(fileURL: url, before: "old", after: "two"))

            async let firstDecision = workspace.awaitDiffDecision(p1)
            _ = await TestSupport.waitUntil { workspace.pendingDiff != nil }
            async let secondDecision = workspace.awaitDiffDecision(p2)
            // The first is force-declined rather than abandoned.
            #expect(await firstDecision == false)
            _ = await TestSupport.waitUntil { workspace.pendingDiff?.id == p2.id }
            workspace.resolvePendingDiff(apply: false)
            #expect(await secondDecision == false)
        }
    }

    @Test func applyProposedEditWritesBufferAndDisk() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("apply.txt", "before", in: dir)
            let outcome = await workspace.applyProposedEdit(url: url, content: "after", replacing: "before")
            #expect(outcome == .applied)
            #expect(try String(contentsOf: url, encoding: .utf8) == "after")
            let doc = try #require(workspace.openedDocument(for: url))
            #expect(doc.text == "after")
            #expect(doc.isDirty == false)
        }
    }

    @Test func applyProposedEditRejectsStaleContent() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("stale.txt", "current", in: dir)
            let outcome = await workspace.applyProposedEdit(url: url, content: "new", replacing: "what-the-diff-saw")
            #expect(outcome == .staleContent)
            #expect(try String(contentsOf: url, encoding: .utf8) == "current")
        }
    }

    @Test func applyProposedEditRefusesNonEditableFile() async throws {
        try await withWorkspace { workspace, dir in
            let url = dir.appending(path: "bin.dat")
            try Data([0x00, 0x01, 0x02]).write(to: url) // NUL ⇒ binary ⇒ not editable
            let outcome = await workspace.applyProposedEdit(url: url, content: "text", replacing: "")
            #expect(outcome == .notWritable)
        }
    }

    // MARK: Trust & project actions

    @Test func untrustedFolderWithExecutableConfigPromptsAndWithholdsEnv() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let config = #"{"env": {"FOO": "bar"}, "actions": [{"name": "build", "command": "make"}]}"#
                try config.write(to: dir.appending(path: ".ibis.json"), atomically: true, encoding: .utf8)

                let workspace = Workspace(rootURL: dir, isDirectory: true)
                #expect(workspace.isTrusted == false)
                #expect(workspace.trustPromptNeeded)
                #expect(workspace.terminal.projectEnv.isEmpty)
                #expect(workspace.availableActions.isEmpty)

                // Declining trust keeps everything withheld and stops prompting.
                workspace.resolveTrust(false)
                #expect(workspace.trustPromptNeeded == false)
                #expect(workspace.availableActions.isEmpty)
                #expect(workspace.terminal.projectEnv.isEmpty)
            }
        }
    }

    @Test func grantingTrustAppliesEnvAndExposesActions() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let config = #"{"env": {"FOO": "bar"}, "actions": [{"name": "build", "command": "make"}]}"#
                try config.write(to: dir.appending(path: ".ibis.json"), atomically: true, encoding: .utf8)

                let workspace = Workspace(rootURL: dir, isDirectory: true)
                workspace.resolveTrust(true)
                #expect(workspace.isTrusted)
                #expect(workspace.terminal.projectEnv == ["FOO": "bar"])
                #expect(workspace.availableActions.map(\.name) == ["build"])

                // A second workspace on the same (now trusted) root skips the prompt.
                let again = Workspace(rootURL: dir, isDirectory: true)
                #expect(again.isTrusted)
                #expect(again.trustPromptNeeded == false)
                #expect(again.terminal.projectEnv == ["FOO": "bar"])
            }
        }
    }

    @Test func cleanConfigNeedsNoTrustPrompt() async throws {
        try await withWorkspace { workspace, _ in
            #expect(workspace.trustPromptNeeded == false)
        }
    }

    @Test func runProjectActionIsNoOpWhenUntrusted() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let config = #"{"actions": [{"name": "evil", "command": "true"}]}"#
                try config.write(to: dir.appending(path: ".ibis.json"), atomically: true, encoding: .utf8)
                let workspace = Workspace(rootURL: dir, isDirectory: true)
                workspace.runProjectAction(ProjectConfig.Action(name: "evil", command: "true"))
                #expect(workspace.isActionRunning == false)
                #expect(workspace.terminal.sessions.isEmpty)
            }
        }
    }

    @Test func commitProjectSettingsReRaisesTrustPromptForExecutableContent() async throws {
        try await withWorkspace { workspace, _ in
            #expect(workspace.trustPromptNeeded == false)
            workspace.projectConfig.envVars = [ProjectConfig.EnvVar(key: "K", value: "v")]
            workspace.commitProjectSettings()
            #expect(workspace.trustPromptNeeded)
        }
    }

    // MARK: Root emptiness

    @Test func refreshRootEmptinessReflectsLoadedChildren() async throws {
        try await withWorkspace { workspace, dir in
            #expect(workspace.rootIsEmpty == false) // not loaded yet
            await workspace.rootNode.loadChildren()
            workspace.refreshRootEmptiness()
            #expect(workspace.rootIsEmpty == true)

            FileManager.default.createFile(atPath: dir.appending(path: "now-nonempty").path, contents: Data())
            await workspace.rootNode.loadChildren(reload: true)
            workspace.refreshRootEmptiness()
            #expect(workspace.rootIsEmpty == false)
        }
    }

    // MARK: Opening & closing via workspace actions

    @Test func openDocumentAtURLOpensAndSelectsATab() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("open-me.txt", "content", in: dir)
            workspace.openDocument(at: url)
            let opened = await TestSupport.waitUntil {
                workspace.activeDocument?.url?.lastPathComponent == "open-me.txt"
            }
            #expect(opened)
            #expect(workspace.activeDocument?.text == "content")

            // Re-opening the same URL focuses the existing tab, not a duplicate.
            workspace.openDocument(at: url)
            _ = await TestSupport.waitUntil { workspace.activeDocument != nil }
            #expect(workspace.layout.activePane?.tabDocuments.count == 1)
        }
    }

    @Test func closeActiveTabClosesTheSelection() async throws {
        try await withWorkspace { workspace, _ in
            let doc = OpenDocument()
            workspace.layout.activePane?.open(doc)
            workspace.closeActiveTab()
            #expect(workspace.layout.activePane?.tabDocuments.isEmpty == true)
        }
    }

    @Test func closeOtherTabsKeepsOnlyTheGivenOne() async throws {
        try await withWorkspace { workspace, _ in
            let pane = try #require(workspace.layout.activePane)
            let keep = OpenDocument(); let a = OpenDocument(); let b = OpenDocument()
            pane.open(a); pane.open(keep); pane.open(b)
            workspace.requestCloseOtherTabs(keeping: keep, in: pane)
            let settled = await TestSupport.waitUntil { pane.tabDocuments.count == 1 }
            #expect(settled)
            #expect(pane.tabDocuments.first?.id == keep.id)
        }
    }

    @Test func closeTabsAfterClosesOnlyTheTail() async throws {
        try await withWorkspace { workspace, _ in
            let pane = try #require(workspace.layout.activePane)
            let a = OpenDocument(); let b = OpenDocument(); let c = OpenDocument()
            pane.open(a); pane.open(b); pane.open(c)
            workspace.requestCloseTabs(after: a, in: pane)
            let settled = await TestSupport.waitUntil { pane.tabDocuments.count == 1 }
            #expect(settled)
            #expect(pane.tabDocuments.first?.id == a.id)
        }
    }

    @Test func saveActiveDocumentWritesAFileBackedDocument() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("save.txt", "v1", in: dir)
            let doc = workspace.document(for: url)
            await doc.loadIfNeeded()
            workspace.layout.activePane?.open(doc)
            doc.text = "v2"
            doc.registerUserEdit()
            await workspace.saveActiveDocument()
            #expect(try String(contentsOf: url, encoding: .utf8) == "v2")
            #expect(doc.isDirty == false)
        }
    }

    // MARK: Directory reloads

    @Test func reloadDirectoryRefreshesALoadedNodeAndNotifies() async throws {
        try await withWorkspace { workspace, dir in
            await workspace.rootNode.loadChildren()
            var notified: FileNode?
            workspace.onDirectoryReloaded = { notified = $0 }

            FileManager.default.createFile(atPath: dir.appending(path: "appeared.txt").path, contents: Data())
            await workspace.reloadDirectory(at: dir)
            #expect(workspace.rootNode.children?.map(\.name) == ["appeared.txt"])
            #expect(notified === workspace.rootNode)
            #expect(workspace.rootIsEmpty == false)
        }
    }

    @Test func reloadDirectoryIgnoresUnloadedNodes() async throws {
        try await withWorkspace { workspace, dir in
            // Root never loaded: reload must not force a load.
            await workspace.reloadDirectory(at: dir)
            #expect(workspace.rootNode.isLoaded == false)
        }
    }

    // MARK: Terminal delegations

    @Test func terminalActionsDriveTheDock() async throws {
        try await withWorkspace { workspace, _ in
            workspace.toggleTerminal()
            #expect(workspace.terminal.isVisible)
            #expect(workspace.terminal.sessions.count == 1)

            workspace.newTerminalTab()
            #expect(workspace.terminal.sessions.count == 2)

            workspace.selectAdjacentTerminal(offset: 1)
            #expect(workspace.terminal.activeSessionID == workspace.terminal.sessions[0].id)

            workspace.closeActiveTerminalTab()
            #expect(workspace.terminal.sessions.count == 1)

            workspace.runAgent(command: "claude", name: "Claude")
            #expect(workspace.terminal.sessions.last?.title == "Claude")
            #expect(workspace.terminal.isVisible)
        }
    }

    @Test func trustedProjectActionRunsAndStops() async throws {
        try await TestSupport.withPreservedDefaults(Self.preservedKeys) {
            try await TestSupport.withTempDir { dir in
                let config = #"{"actions": [{"name": "noop", "command": "true"}]}"#
                try config.write(to: dir.appending(path: ".ibis.json"), atomically: true, encoding: .utf8)
                let workspace = Workspace(rootURL: dir, isDirectory: true)
                workspace.resolveTrust(true)

                workspace.runProjectAction(ProjectConfig.Action(name: "noop", command: "true"))
                #expect(workspace.isActionRunning)
                #expect(workspace.terminal.runSession != nil)
                workspace.stopProjectAction()
                #expect(workspace.isActionRunning == false)
            }
        }
    }

    // MARK: Reveal-in-tree hand-off

    @Test func revealIsQueuedUntilTheBrowserConnects() async throws {
        try await withWorkspace { workspace, dir in
            let url = try writeFile("reveal.txt", "x", in: dir)
            workspace.requestRevealInTree(url) // no browser mounted
            #expect(workspace.pendingReveal == url)

            var received: URL?
            workspace.onRevealInTree = { received = $0 }
            workspace.requestRevealInTree(url)
            #expect(received == url)
        }
    }
}
