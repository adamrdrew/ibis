import Testing
import Foundation
@testable import Ibis

@MainActor
@Suite struct OpenDocumentTests {
    // MARK: - Identity & format

    @Test func untitledDocumentStartsCleanAndLoaded() {
        let doc = OpenDocument()
        #expect(doc.isUntitled)
        #expect(doc.name == "Untitled")
        #expect(doc.isLoaded)
        #expect(doc.isDirty == false)
        #expect(doc.isEditable)
    }

    @Test(arguments: [
        ("readme.md", OpenDocument.Format.markdown),
        ("page.html", .html),
        ("Main.swift", .source),
        ("data.json", .source),
    ])
    func formatDerivedFromExtension(name: String, expected: OpenDocument.Format) {
        #expect(OpenDocument.format(forExtension: (name as NSString).pathExtension) == expected)
    }

    @Test func markdownOpensRenderedButHTMLOpensAsSource() {
        // A file-backed .html opens as source so a click can't auto-run its JS.
        #expect(OpenDocument(url: URL(filePath: "/proj/notes.md")).showsPreview)
        #expect(OpenDocument(url: URL(filePath: "/proj/page.html")).showsPreview == false)
    }

    @Test func ephemeralDocumentHoldsSuppliedContent() {
        let doc = OpenDocument(title: "Summary", text: "hello", format: .markdown)
        #expect(doc.name == "Summary")
        #expect(doc.isUntitled)
        #expect(doc.text == "hello")
        #expect(doc.showsPreview)
    }

    // MARK: - Edit tracking

    @Test func registerUserEditMarksDirty() {
        let doc = OpenDocument()
        doc.text = "typed"
        doc.registerUserEdit()
        #expect(doc.isDirty)
    }

    @Test func programmaticTextReplacementBumpsContentVersion() {
        let doc = OpenDocument()
        let before = doc.contentVersion
        doc.text = "new content"
        #expect(doc.text == "new content")
        #expect(doc.contentVersion == before + 1)
    }

    @Test func programmaticTextReplacementClearsTheUndoStack() {
        let doc = OpenDocument()
        doc.text = "hello world"
        // Simulate a recorded user edit whose undo range points into this text.
        doc.undoManager.registerUndo(withTarget: doc) { _ in }
        #expect(doc.undoManager.canUndo)

        // A programmatic replacement (load, revert, applied agent edit) must
        // invalidate the stack — even with no editor mounted, where the
        // view-layer clear can't run. A stale action replayed against shorter
        // text raises an out-of-range exception.
        doc.text = "short"
        #expect(!doc.undoManager.canUndo)
    }

    // MARK: - Load

    @Test func loadReadsFileContents() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "on disk".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            #expect(doc.isLoaded)
            #expect(doc.text == "on disk")
            #expect(doc.isDirty == false)
            #expect(doc.isEditable)
        }
    }

    @Test func binaryFileLoadsReadOnly() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "blob.bin")
            var bytes = Data("start".utf8); bytes.append(0); bytes.append(Data("end".utf8))
            try bytes.write(to: url)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            #expect(doc.isBinary)
            #expect(doc.isEditable == false)
        }
    }

    @Test func invalidUTF8LoadsReadOnly() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "latin1.txt")
            try Data([0x66, 0x6f, 0x6f, 0xFF]).write(to: url) // "foo" + invalid byte, no NUL
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            #expect(doc.isBinary == false)
            #expect(doc.readOnlyReason != nil)
            #expect(doc.isEditable == false)
        }
    }

    // MARK: - Save

    @Test func saveWritesToDiskAndClearsDirty() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "out.txt")
            try "".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            doc.text = "written by test"
            doc.registerUserEdit()
            #expect(doc.isDirty)
            #expect(await doc.save().didSave)
            #expect(doc.isDirty == false)
            #expect(try String(contentsOf: url, encoding: .utf8) == "written by test")
        }
    }

    @Test func savingUntitledDocumentFails() async {
        let doc = OpenDocument()
        doc.text = "x"
        doc.registerUserEdit()
        guard case .noURL = await doc.save() else {
            Issue.record("an untitled document has nowhere to save to")
            return
        }
    }

    /// The core anti-clobber guarantee: a save must consult *disk*, not the
    /// FSEvents-driven `hasExternalChanges` flag. No `reconcileWithDisk()` call
    /// here on purpose — that models the real race, where the user hits ⌘S
    /// inside the watcher's latency and the flag is still stale.
    @Test func saveRefusesToClobberAnUnnoticedExternalChange() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "v1".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            doc.text = "my unsaved work"
            doc.registerUserEdit()

            try "written by the agent".write(to: url, atomically: true, encoding: .utf8)
            #expect(doc.hasExternalChanges == false) // nothing has reconciled yet

            guard case .conflict = await doc.save() else {
                Issue.record("save overwrote a change made outside Ibis")
                return
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "written by the agent")
            #expect(doc.isDirty)
            #expect(doc.text == "my unsaved work")
            // The refused save is what noticed the divergence, so the editor's
            // "changed on disk" banner must now be up.
            #expect(doc.hasExternalChanges)
        }
    }

    @Test func forcedSaveOverwritesAnExternalChange() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "v1".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            doc.text = "mine"
            doc.registerUserEdit()
            try "theirs".write(to: url, atomically: true, encoding: .utf8)

            #expect(await doc.save(force: true).didSave)
            #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
            #expect(doc.isDirty == false)
            #expect(doc.hasExternalChanges == false)
        }
    }

    /// The conflict check must not fire on our own writes — including a second
    /// save right after the first, which compares against the metadata the first
    /// one recorded.
    @Test func repeatedSavesDoNotReportAConflict() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "v1".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            doc.text = "second"
            doc.registerUserEdit()
            #expect(await doc.save().didSave)
            doc.text = "third and rather longer"
            doc.registerUserEdit()
            #expect(await doc.save().didSave)
            #expect(try String(contentsOf: url, encoding: .utf8) == "third and rather longer")
        }
    }

    /// The save-time stat must resolve symlinks the same way the write and
    /// `reconcileWithDisk` do — statting the link's own inode would report a
    /// conflict on every save through a symlink.
    @Test func savingThroughASymlinkDoesNotReportAConflict() async throws {
        try await TestSupport.withTempDir { dir in
            let target = dir.appending(path: "real.txt")
            let link = dir.appending(path: "link.txt")
            try "v1".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let doc = OpenDocument(url: link)
            await doc.loadIfNeeded()
            doc.text = "through the link"
            doc.registerUserEdit()
            #expect(await doc.save().didSave)
            #expect(try String(contentsOf: target, encoding: .utf8) == "through the link")
        }
    }

    /// A vanished file is not a conflict: there's nothing to clobber, and the
    /// editor's banner promises that saving recreates it.
    @Test func savingRecreatesADeletedFile() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "v1".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            doc.text = "kept"
            doc.registerUserEdit()
            try FileManager.default.removeItem(at: url)
            await doc.reconcileWithDisk()
            #expect(doc.isFileMissing)

            #expect(await doc.save().didSave)
            #expect(try String(contentsOf: url, encoding: .utf8) == "kept")
            #expect(doc.isFileMissing == false)
        }
    }

    // MARK: - Save As / adopt

    @Test func adoptSavedFileRetargetsAndCleansDirty() throws {
        try TestSupport.withTempDir { dir in
            let doc = OpenDocument()
            doc.text = "content"
            doc.registerUserEdit()
            let url = dir.appending(path: "saved-as.swift")
            try doc.text.write(to: url, atomically: true, encoding: .utf8)
            doc.adoptSavedFile(at: url)
            #expect(doc.isUntitled == false)
            #expect(doc.url == url)
            #expect(doc.name == "saved-as.swift")
            #expect(doc.isDirty == false)
            #expect(doc.format == .source)
        }
    }

    // MARK: - Revert & reconcile

    @Test func revertRestoresDiskContents() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "original".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            doc.text = "unsaved edit"
            doc.registerUserEdit()
            await doc.revertToSaved(force: true)
            #expect(doc.text == "original")
            #expect(doc.isDirty == false)
        }
    }

    @Test func reconcileFlagsAMissingFile() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "here".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            try FileManager.default.removeItem(at: url)
            await doc.reconcileWithDisk()
            #expect(doc.isFileMissing)
        }
    }

    @Test func reconcileReloadsACleanBufferAfterExternalChange() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "v1".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()

            // Change size too, so the check can't miss on mtime granularity.
            try "v2 external".write(to: url, atomically: true, encoding: .utf8)
            await doc.reconcileWithDisk()
            #expect(doc.text == "v2 external")
            #expect(doc.hasExternalChanges == false)
            #expect(doc.isDirty == false)
        }
    }

    @Test func reconcileFlagsButKeepsADirtyBufferAfterExternalChange() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "v1".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            doc.text = "my unsaved work"
            doc.registerUserEdit()

            try "v2 external".write(to: url, atomically: true, encoding: .utf8)
            await doc.reconcileWithDisk()
            // The user's edits survive; the divergence is flagged, not resolved.
            #expect(doc.text == "my unsaved work")
            #expect(doc.hasExternalChanges)
            #expect(doc.isDirty)
        }
    }

    @Test func reconcileAfterOurOwnSaveSeesNoChange() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "v1".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            doc.text = "v2 via ibis"
            doc.registerUserEdit()
            _ = await doc.save()

            // Our own write recorded its metadata; reconcile must be a no-op.
            await doc.reconcileWithDisk()
            #expect(doc.text == "v2 via ibis")
            #expect(doc.hasExternalChanges == false)
            #expect(doc.isFileMissing == false)
        }
    }

    @Test func reconcileReappearedFileClearsTheMissingFlag() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "here".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            await doc.loadIfNeeded()
            try FileManager.default.removeItem(at: url)
            await doc.reconcileWithDisk()
            #expect(doc.isFileMissing)

            try "back again".write(to: url, atomically: true, encoding: .utf8)
            await doc.reconcileWithDisk()
            #expect(doc.isFileMissing == false)
            #expect(doc.text == "back again")
        }
    }

    @Test func assignURLUpdatesNameAndFormat() {
        let doc = OpenDocument(title: "Draft", text: "# hi", format: .markdown)
        doc.assignURL(URL(filePath: "/proj/final.html"))
        #expect(doc.name == "final.html")
        #expect(doc.format == .html)
        #expect(doc.isUntitled == false)
    }

    @Test func loadFailureIsReportedAndBlocksEditing() async {
        let doc = OpenDocument(url: URL(filePath: "/nonexistent-\(UUID().uuidString).txt"))
        await doc.loadIfNeeded()
        #expect(doc.loadError != nil)
        #expect(doc.isEditable == false)
    }

    @Test func overlappingLoadsShareOneRead() async throws {
        try await TestSupport.withTempDir { dir in
            let url = dir.appending(path: "a.txt")
            try "content".write(to: url, atomically: true, encoding: .utf8)
            let doc = OpenDocument(url: url)
            // Two concurrent loads (a click and its selection task) must not
            // double-apply — contentVersion advances exactly once.
            async let first: Void = doc.loadIfNeeded()
            async let second: Void = doc.loadIfNeeded()
            _ = await (first, second)
            #expect(doc.text == "content")
            #expect(doc.contentVersion == 1)
        }
    }
}
