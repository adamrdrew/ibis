import Testing
import Foundation
import AppKit
@testable import Ibis

/// Exercises the MCP bridge headlessly: token routing, workspace containment,
/// the propose/review/apply flow (driven by resolving the pending diff the way
/// the sheet's buttons would), and format inference for agent content.
/// Serialized: the bridge is a process-wide singleton.
@MainActor
@Suite(.serialized) struct MCPBridgeTests {
    /// A registered workspace over a fresh temp dir, unregistered afterward so
    /// state can't leak between tests through the shared bridge.
    private func withBridgedWorkspace<T>(
        _ body: (Workspace, String, URL) async throws -> T
    ) async throws -> T {
        try await TestSupport.withIsolatedDefaults {
            try await TestSupport.withTempDir { dir in
                let workspace = Workspace(rootURL: dir, isDirectory: true)
                let token = MCPBridge.shared.register(workspace)
                defer { MCPBridge.shared.unregister(workspace) }
                return try await body(workspace, token, dir)
            }
        }
    }

    // MARK: Registry & routing

    @Test func registerReturnsAStableToken() async throws {
        try await withBridgedWorkspace { workspace, token, _ in
            #expect(!token.isEmpty)
            #expect(MCPBridge.shared.token(for: workspace) == token)
            #expect(MCPBridge.shared.register(workspace) == token)
            #expect(MCPTokenRegistry.shared.contains(token))
        }
    }

    @Test func unknownTokenIsRejected() async throws {
        try await withBridgedWorkspace { _, _, _ in
            await #expect(throws: MCPBridgeError.self) {
                _ = try await MCPBridge.shared.openFile(token: "bogus", path: "x.txt", line: nil)
            }
            await #expect(throws: MCPBridgeError.self) {
                _ = try MCPBridge.shared.workspaceRootPath(token: nil)
            }
        }
    }

    @Test func unregisterInvalidatesTheToken() async throws {
        try await TestSupport.withIsolatedDefaults {
            try await TestSupport.withTempDir { dir in
                let workspace = Workspace(rootURL: dir, isDirectory: true)
                let token = MCPBridge.shared.register(workspace)
                MCPBridge.shared.unregister(workspace)
                #expect(MCPTokenRegistry.shared.contains(token) == false)
                #expect(throws: MCPBridgeError.self) {
                    _ = try MCPBridge.shared.workspaceRootPath(token: token)
                }
            }
        }
    }

    // MARK: Path containment

    @Test(arguments: [
        "../outside.txt",
        "/etc/hosts",
        "~/.ssh/config",
        "sub/../../escape.txt",
    ])
    func pathsOutsideTheWorkspaceAreRefused(path: String) async throws {
        try await withBridgedWorkspace { _, token, _ in
            await #expect(throws: MCPToolFailure.self) {
                _ = try await MCPBridge.shared.openFile(token: token, path: path, line: nil)
            }
            #expect(throws: MCPToolFailure.self) {
                _ = try MCPBridge.shared.revealInTree(token: token, path: path)
            }
        }
    }

    @Test func relativeAndAbsoluteInWorkspacePathsResolve() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "ok.txt")
            try "fine".write(to: url, atomically: true, encoding: .utf8)

            let viaRelative = try await MCPBridge.shared.openFile(token: token, path: "ok.txt", line: nil)
            #expect(viaRelative.contains("ok.txt"))
            let viaAbsolute = try await MCPBridge.shared.openFile(
                token: token, path: url.path(percentEncoded: false), line: nil
            )
            #expect(viaAbsolute.contains("ok.txt"))
            #expect(workspace.activeDocument?.url?.lastPathComponent == "ok.txt")
        }
    }

    @Test func openFileReportsAMissingFile() async throws {
        try await withBridgedWorkspace { _, token, _ in
            await #expect(throws: MCPToolFailure.self) {
                _ = try await MCPBridge.shared.openFile(token: token, path: "missing.txt", line: nil)
            }
        }
    }

    // MARK: Read-side tools

    @Test func activeFileOpenTabsAndRootReflectTheWorkspace() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            #expect(try MCPBridge.shared.activeFilePath(token: token) == "(no file open)")
            #expect(try MCPBridge.shared.openTabPaths(token: token).isEmpty)
            #expect(try MCPBridge.shared.workspaceRootPath(token: token) == dir.path)

            let url = dir.appending(path: "tab.txt")
            try "t".write(to: url, atomically: true, encoding: .utf8)
            _ = try await MCPBridge.shared.openFile(token: token, path: "tab.txt", line: nil)
            #expect(try MCPBridge.shared.activeFilePath(token: token) == url.path)
            #expect(try MCPBridge.shared.openTabPaths(token: token) == [url.path])
        }
    }

    @Test func notifySetsTheBannerForTheCallingWindow() async throws {
        try await withBridgedWorkspace { _, token, _ in
            try MCPBridge.shared.notify(token: token, message: "done!")
            #expect(MCPBridge.shared.banner == "done!")
            #expect(MCPBridge.shared.bannerToken == token)
            MCPBridge.shared.banner = nil
            MCPBridge.shared.bannerToken = nil
        }
    }

    @Test func askHumanFailsHonestlyWithoutAWindow() async throws {
        try await withBridgedWorkspace { _, token, _ in
            await #expect(throws: MCPBridgeError.self) {
                _ = try await MCPBridge.shared.askHuman(token: token, question: "sure?", options: nil)
            }
        }
    }

    // MARK: propose_edit / propose_patch

    @Test func proposeEditAppliesAfterApproval() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "edit.txt")
            try "old content".write(to: url, atomically: true, encoding: .utf8)

            async let result = MCPBridge.shared.proposeEdit(
                token: token, path: "edit.txt", newContent: "new content"
            )
            let presented = await TestSupport.waitUntil { workspace.pendingDiff != nil }
            #expect(presented)
            #expect(workspace.pendingDiff?.displayName == "edit.txt")
            workspace.resolvePendingDiff(apply: true)

            let message = try await result
            #expect(message.contains("Applied"))
            #expect(try String(contentsOf: url, encoding: .utf8) == "new content")
        }
    }

    @Test func proposeEditDeclineLeavesTheFileAlone() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "edit.txt")
            try "keep me".write(to: url, atomically: true, encoding: .utf8)

            async let result = MCPBridge.shared.proposeEdit(
                token: token, path: "edit.txt", newContent: "clobber"
            )
            _ = await TestSupport.waitUntil { workspace.pendingDiff != nil }
            workspace.resolvePendingDiff(apply: false)

            let message = try await result
            #expect(message.contains("declined"))
            #expect(try String(contentsOf: url, encoding: .utf8) == "keep me")
        }
    }

    @Test func proposeEditWithIdenticalContentShortCircuits() async throws {
        try await withBridgedWorkspace { _, token, dir in
            let url = dir.appending(path: "same.txt")
            try "same".write(to: url, atomically: true, encoding: .utf8)
            let message = try await MCPBridge.shared.proposeEdit(token: token, path: "same.txt", newContent: "same")
            #expect(message.contains("No changes"))
        }
    }

    @Test func proposePatchAppliesASurgicalEdit() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "patch.txt")
            try "alpha beta gamma".write(to: url, atomically: true, encoding: .utf8)

            async let result = MCPBridge.shared.proposePatch(
                token: token, path: "patch.txt",
                edits: [ProposedEdit(oldString: "beta", newString: "BETA", replaceAll: nil)]
            )
            _ = await TestSupport.waitUntil { workspace.pendingDiff != nil }
            workspace.resolvePendingDiff(apply: true)
            _ = try await result
            #expect(try String(contentsOf: url, encoding: .utf8) == "alpha BETA gamma")
        }
    }

    @Test func proposePatchReplaceAllReplacesEveryOccurrence() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "patch.txt")
            try "x y x y x".write(to: url, atomically: true, encoding: .utf8)

            async let result = MCPBridge.shared.proposePatch(
                token: token, path: "patch.txt",
                edits: [ProposedEdit(oldString: "x", newString: "z", replaceAll: true)]
            )
            _ = await TestSupport.waitUntil { workspace.pendingDiff != nil }
            workspace.resolvePendingDiff(apply: true)
            _ = try await result
            #expect(try String(contentsOf: url, encoding: .utf8) == "z y z y z")
        }
    }

    @Test func proposePatchRejectsBadEditsBeforeAnyReview() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "patch.txt")
            try "one two two".write(to: url, atomically: true, encoding: .utf8)

            // No edits at all.
            await #expect(throws: MCPToolFailure.self) {
                _ = try await MCPBridge.shared.proposePatch(token: token, path: "patch.txt", edits: [])
            }
            // Empty oldString.
            await #expect(throws: MCPToolFailure.self) {
                _ = try await MCPBridge.shared.proposePatch(
                    token: token, path: "patch.txt",
                    edits: [ProposedEdit(oldString: "", newString: "x", replaceAll: nil)]
                )
            }
            // Not found.
            await #expect(throws: MCPToolFailure.self) {
                _ = try await MCPBridge.shared.proposePatch(
                    token: token, path: "patch.txt",
                    edits: [ProposedEdit(oldString: "absent", newString: "x", replaceAll: nil)]
                )
            }
            // Ambiguous without replaceAll.
            await #expect(throws: MCPToolFailure.self) {
                _ = try await MCPBridge.shared.proposePatch(
                    token: token, path: "patch.txt",
                    edits: [ProposedEdit(oldString: "two", newString: "2", replaceAll: nil)]
                )
            }
            // None of those ever raised a review.
            #expect(workspace.pendingDiff == nil)
        }
    }

    @Test func proposeEditDiffsAgainstTheOpenBufferNotDisk() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "buffer.txt")
            try "disk".write(to: url, atomically: true, encoding: .utf8)
            let doc = workspace.document(for: url)
            await doc.loadIfNeeded()
            doc.text = "unsaved buffer"
            doc.registerUserEdit()

            // Proposing the buffer's own content is "no change" even though disk differs.
            let message = try await MCPBridge.shared.proposeEdit(
                token: token, path: "buffer.txt", newContent: "unsaved buffer"
            )
            #expect(message.contains("No changes"))
        }
    }

    @Test func secondReviewWhileOneIsOpenIsRefused() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "busy.txt")
            try "v0".write(to: url, atomically: true, encoding: .utf8)

            async let first = MCPBridge.shared.proposeEdit(token: token, path: "busy.txt", newContent: "v1")
            _ = await TestSupport.waitUntil { workspace.pendingDiff != nil }
            await #expect(throws: MCPToolFailure.self) {
                _ = try await MCPBridge.shared.proposeEdit(token: token, path: "busy.txt", newContent: "v2")
            }
            workspace.resolvePendingDiff(apply: false)
            _ = try await first
        }
    }

    // MARK: Selection & focused editor

    @Test func currentSelectionIsEmptyWithoutAFocusedEditor() async throws {
        try await withBridgedWorkspace { _, token, _ in
            let selection = try MCPBridge.shared.currentSelection(token: token)
            #expect(selection == "")
        }
    }

    @Test func currentSelectionReadsTheFocusedEditor() async throws {
        try await withBridgedWorkspace { workspace, token, _ in
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            textView.string = "pick the middle word"
            textView.setSelectedRange(NSRange(location: 9, length: 6)) // "middle"
            workspace.focusedEditor = textView
            let selected = try MCPBridge.shared.currentSelection(token: token)
            #expect(selected == "middle")

            textView.setSelectedRange(NSRange(location: 0, length: 0))
            let collapsed = try MCPBridge.shared.currentSelection(token: token)
            #expect(collapsed == "")
        }
    }

    @Test func noteFocusedEditorAttributesToTheRightWindow() async throws {
        try await withBridgedWorkspace { workspace, _, _ in
            // A bare, never-shown window is enough to exercise the routing.
            // ARC owns these windows — AppKit must not also release them on
            // close, or the double release segfaults during pool drain.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: true
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            workspace.window = window
            let textView = NSTextView()
            MCPBridge.shared.noteFocusedEditor(textView, in: window)
            #expect(workspace.focusedEditor === textView)

            // An editor in some other window must not be attributed here.
            let other = NSWindow(
                contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true
            )
            other.isReleasedWhenClosed = false
            defer { other.close() }
            let foreign = NSTextView()
            MCPBridge.shared.noteFocusedEditor(foreign, in: other)
            #expect(workspace.focusedEditor === textView)
        }
    }

    @Test func openFileWithLineQueuesTheSelection() async throws {
        try await withBridgedWorkspace { workspace, token, dir in
            let url = dir.appending(path: "goto.txt")
            try "one\ntwo\nthree".write(to: url, atomically: true, encoding: .utf8)
            _ = try await MCPBridge.shared.openFile(token: token, path: "goto.txt", line: 3)
            let doc = try #require(workspace.activeDocument)
            let ns = doc.text as NSString
            #expect(doc.pendingSelection == ns.range(of: "three"))
        }
    }

    // MARK: open_content & format inference

    @Test func openContentCreatesAnEphemeralTab() async throws {
        try await withBridgedWorkspace { workspace, token, _ in
            let message = try MCPBridge.shared.openContent(
                token: token, title: "Report", content: "# Hi", format: "markdown"
            )
            #expect(message.contains("Report"))
            let doc = try #require(workspace.activeDocument)
            #expect(doc.isUntitled)
            #expect(doc.name == "Report")
            #expect(doc.format == .markdown)
            #expect(doc.showsPreview)
        }
    }

    @Test func openContentBlankTitleBecomesUntitled() async throws {
        try await withBridgedWorkspace { workspace, token, _ in
            _ = try MCPBridge.shared.openContent(token: token, title: "   ", content: "x", format: "text")
            #expect(workspace.activeDocument?.name == "Untitled")
            #expect(workspace.activeDocument?.format == .source)
        }
    }

    @Test(arguments: [
        ("html", "plain words", OpenDocument.Format.html),        // explicit wins
        ("md", "plain words", OpenDocument.Format.markdown),
        ("plain", "# looks like md", OpenDocument.Format.source),
        ("wat", "anything", OpenDocument.Format.markdown),        // unknown explicit → markdown
        (nil, "<!doctype html><p>x</p>", OpenDocument.Format.html),  // inferred html
        (nil, "<html><body>x</body></html>", OpenDocument.Format.html),
        (nil, "# heading", OpenDocument.Format.markdown),         // inferred default
    ] as [(String?, String, OpenDocument.Format)])
    func openContentResolvesFormat(format: String?, content: String, expected: OpenDocument.Format) async throws {
        try await withBridgedWorkspace { workspace, token, _ in
            _ = try MCPBridge.shared.openContent(token: token, title: "T", content: content, format: format)
            #expect(workspace.activeDocument?.format == expected)
        }
    }
}
