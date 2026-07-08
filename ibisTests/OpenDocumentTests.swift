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
            let ok = await doc.save()
            #expect(ok)
            #expect(doc.isDirty == false)
            #expect(try String(contentsOf: url, encoding: .utf8) == "written by test")
        }
    }

    @Test func savingUntitledDocumentFails() async {
        let doc = OpenDocument()
        doc.text = "x"
        doc.registerUserEdit()
        let ok = await doc.save()
        #expect(ok == false)
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
