import Testing
import AppKit
import SwiftUI
@testable import Ibis

/// Exercises the file browser's `FileOutlineView.Coordinator` headlessly with
/// an off-window `NSOutlineView`: the FSEvents→reload bridge (including the
/// deferral of reloads while an inline rename is being edited), per-target
/// rename in-flight guarding, and drag spring-load cancellation. What can't be
/// driven without a real window — the field-editor teardown chain itself
/// (`editColumn` → reload → `controlTextDidEndEditing`) — is covered
/// indirectly: the fix guarantees the reload never reaches the outline view
/// while editing, so that chain can no longer start.
/// Serialized: workspaces touch shared UserDefaults keys (trust, layout).
@MainActor
@Suite(.serialized) struct FileOutlineViewTests {
    /// Builds a workspace over a fresh temp dir plus a coordinator-wired
    /// outline view (mirroring `makeNSView`), and runs `body`.
    private func withTree<T>(
        _ body: (Workspace, URL, FileOutlineView.Coordinator, TreeOutlineView) async throws -> T
    ) async throws -> T {
        try await TestSupport.withIsolatedDefaults {
            try await TestSupport.withTempDir { dir in
                let workspace = Workspace(rootURL: dir, isDirectory: true)
                let coordinator = FileOutlineView.Coordinator(
                    workspace: workspace,
                    selection: .constant(nil)
                )
                let outlineView = TreeOutlineView()
                outlineView.headerView = nil
                let column = NSTableColumn(identifier: .init("name"))
                outlineView.addTableColumn(column)
                outlineView.outlineTableColumn = column
                outlineView.dataSource = coordinator
                outlineView.delegate = coordinator
                outlineView.coordinator = coordinator
                coordinator.outlineView = outlineView
                coordinator.installReloadBridge()
                outlineView.reloadData()
                return try await body(workspace, dir, coordinator, outlineView)
            }
        }
    }

    @discardableResult
    private func writeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func node(named name: String, in outlineView: NSOutlineView) -> FileNode? {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, node.name == name {
                return node
            }
        }
        return nil
    }

    private func rowNames(in outlineView: NSOutlineView) -> Set<String> {
        Set((0..<outlineView.numberOfRows).compactMap {
            (outlineView.item(atRow: $0) as? FileNode)?.name
        })
    }

    // MARK: Reload bridge & inline-rename deferral

    @Test func reloadBridgeAppliesImmediatelyWhenNotEditing() async throws {
        try await withTree { workspace, dir, _, outlineView in
            try writeFile("a.txt", in: dir)
            await workspace.reloadDirectory(at: dir)
            #expect(rowNames(in: outlineView).contains("a.txt"))
        }
    }

    @Test func reloadsDeferredDuringInlineRenameAndFlushedAfter() async throws {
        try await withTree { workspace, dir, coordinator, outlineView in
            try writeFile("a.txt", in: dir)
            await workspace.reloadDirectory(at: dir)
            #expect(outlineView.numberOfRows == 1)

            // The user is mid-rename (has typed into the field editor).
            let field = NSTextField(labelWithString: "")
            coordinator.controlTextDidBeginEditing(
                Notification(name: NSControl.textDidBeginEditingNotification, object: field)
            )

            // A background change (build output, git checkout) lands.
            try writeFile("b.txt", in: dir)
            await workspace.reloadDirectory(at: dir)

            // The outline view must NOT reload mid-edit: doing so reconfigures
            // the edited cell and tears down the field editor, committing the
            // half-typed name as a rename.
            #expect(outlineView.numberOfRows == 1)

            // Editing ends → the deferred reload applies; nothing was lost.
            coordinator.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: field)
            )
            #expect(rowNames(in: outlineView) == ["a.txt", "b.txt"])
        }
    }

    @Test func endEditingWithoutDeferredReloadsIsHarmless() async throws {
        try await withTree { workspace, dir, coordinator, outlineView in
            try writeFile("a.txt", in: dir)
            await workspace.reloadDirectory(at: dir)
            let field = NSTextField(labelWithString: "")
            coordinator.controlTextDidBeginEditing(
                Notification(name: NSControl.textDidBeginEditingNotification, object: field)
            )
            coordinator.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: field)
            )
            #expect(rowNames(in: outlineView) == ["a.txt"])
        }
    }

    // MARK: Rename in-flight guarding

    @Test func secondRenameOfDifferentFileIsNotDropped() async throws {
        try await withTree { workspace, dir, coordinator, outlineView in
            try writeFile("a.txt", in: dir)
            try writeFile("b.txt", in: dir)
            await workspace.reloadDirectory(at: dir)
            let nodeA = try #require(node(named: "a.txt", in: outlineView))
            let nodeB = try #require(node(named: "b.txt", in: outlineView))

            // Commit rename A, then rename B while A's async reload is still
            // in flight. A global in-flight flag used to swallow B silently.
            let fieldA = NSTextField(labelWithString: "")
            fieldA.stringValue = "a2.txt"
            coordinator.performRename(of: nodeA, from: fieldA)

            let fieldB = NSTextField(labelWithString: "")
            fieldB.stringValue = "b2.txt"
            coordinator.performRename(of: nodeB, from: fieldB)

            let fm = FileManager.default
            #expect(fm.fileExists(atPath: dir.appending(path: "a2.txt").path))
            #expect(fm.fileExists(atPath: dir.appending(path: "b2.txt").path))
            #expect(!fm.fileExists(atPath: dir.appending(path: "a.txt").path))
            #expect(!fm.fileExists(atPath: dir.appending(path: "b.txt").path))

            // Let both in-flight reloads settle before the temp dir vanishes.
            #expect(await TestSupport.waitUntil {
                rowNames(in: outlineView) == ["a2.txt", "b2.txt"]
            })
        }
    }

    @Test func doubleCommitOfSameRenameRunsOnce() async throws {
        try await withTree { workspace, dir, coordinator, outlineView in
            try writeFile("a.txt", in: dir)
            await workspace.reloadDirectory(at: dir)
            let nodeA = try #require(node(named: "a.txt", in: outlineView))

            // The Return action and the end-editing notification both invoke
            // the rename for one commit; the second call must be a no-op (it
            // would otherwise fail against the now-missing old name and revert
            // the field).
            let field = NSTextField(labelWithString: "")
            field.stringValue = "a2.txt"
            coordinator.performRename(of: nodeA, from: field)
            coordinator.performRename(of: nodeA, from: field)

            #expect(field.stringValue == "a2.txt") // not reverted by a failed retry
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: dir.appending(path: "a2.txt").path))
            #expect(!fm.fileExists(atPath: dir.appending(path: "a.txt").path))

            #expect(await TestSupport.waitUntil {
                rowNames(in: outlineView) == ["a2.txt"]
            })
        }
    }

    // MARK: Drag spring-loading

    /// Minimal `NSDraggingInfo` for driving `validateDrop` headless.
    private final class DragInfoStub: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .move }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { NSPasteboard(name: .init("ibisTests.drag")) }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 0 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination: Bool = false
        var numberOfValidItemsForDrop: Int = 0
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions,
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// Positive control: hovering a collapsed folder arms the spring and it
    /// fires (proves the negative tests below aren't vacuously green).
    @Test func springExpandsHoveredCollapsedFolder() async throws {
        try await withTree { workspace, dir, coordinator, outlineView in
            try FileManager.default.createDirectory(at: dir.appending(path: "folder"), withIntermediateDirectories: true)
            await workspace.reloadDirectory(at: dir)
            let folder = try #require(node(named: "folder", in: outlineView))

            _ = coordinator.outlineView(
                outlineView, validateDrop: DragInfoStub(), proposedItem: folder, proposedChildIndex: -1
            )
            #expect(await TestSupport.waitUntil(timeout: 3) {
                outlineView.isItemExpanded(folder)
            })
        }
    }

    @Test func springCancelledWhenDragMovesOntoFileRow() async throws {
        try await withTree { workspace, dir, coordinator, outlineView in
            try FileManager.default.createDirectory(at: dir.appending(path: "folder"), withIntermediateDirectories: true)
            try writeFile("a.txt", in: dir)
            await workspace.reloadDirectory(at: dir)
            let folder = try #require(node(named: "folder", in: outlineView))
            let file = try #require(node(named: "a.txt", in: outlineView))
            let info = DragInfoStub()

            // Hover the collapsed folder (arms the 0.65s spring), then move
            // onto a plain file row — the early "no drop here" return must
            // still disarm the spring, or it fires after the drag moved on.
            _ = coordinator.outlineView(
                outlineView, validateDrop: info, proposedItem: folder, proposedChildIndex: -1
            )
            let op = coordinator.outlineView(
                outlineView, validateDrop: info, proposedItem: file, proposedChildIndex: -1
            )
            #expect(op == [])

            try await Task.sleep(for: .milliseconds(900))
            #expect(!outlineView.isItemExpanded(folder))
        }
    }

    @Test func springCancelledWhenDragSessionEnds() async throws {
        try await withTree { workspace, dir, coordinator, outlineView in
            try FileManager.default.createDirectory(at: dir.appending(path: "folder"), withIntermediateDirectories: true)
            await workspace.reloadDirectory(at: dir)
            let folder = try #require(node(named: "folder", in: outlineView))
            let info = DragInfoStub()

            _ = coordinator.outlineView(
                outlineView, validateDrop: info, proposedItem: folder, proposedChildIndex: -1
            )
            // The drag ends (drop or release) while the spring is still armed.
            // Drive the coordinator's disarm directly — `TreeOutlineView.
            // draggingEnded` is a one-line call to it plus `super`, and AppKit's
            // super implementation calls private NSDraggingInfo methods a stub
            // can't provide: the resulting NSException unwinds the test task
            // uncatchably and wedges the entire test run (the main-thread task
            // never completes, so Swift Testing waits forever).
            coordinator.cancelSpring()

            try await Task.sleep(for: .milliseconds(900))
            #expect(!outlineView.isItemExpanded(folder))
        }
    }
}
