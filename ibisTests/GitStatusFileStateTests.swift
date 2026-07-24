import Testing
import Foundation
@testable import Ibis

/// The per-file half of the porcelain parser — what the file browser decorates
/// rows with. Driven with canned `git status --porcelain=v2` output, so no git
/// process is involved.
@Suite struct GitStatusFileStateTests {
    private let header = """
    # branch.oid abcdef1
    # branch.head main
    """

    private func parse(_ entries: String, paths: GitStatusModel.PathMapper? = nil) -> GitStatusModel.Info {
        GitStatusModel.parse(header + "\n" + entries, paths: paths)
    }

    @Test func modifiedAndStagedFiles() {
        let info = parse("""
        1 .M N... 100644 100644 100644 abc abc src/app.swift
        1 A. N... 000000 100644 100644 000000 abc src/new.swift
        1 M. N... 100644 100644 100644 abc abc staged.swift
        """)
        #expect(info.isDirty)
        #expect(info.change(at: "src/app.swift") == .modified)
        #expect(info.change(at: "src/new.swift") == .added)
        // Staged-only edits still read as modified — the working-tree column is
        // "." there, so the index column decides.
        #expect(info.change(at: "staged.swift") == .modified)
        #expect(info.change(at: "untouched.swift") == nil)
    }

    @Test func workingTreeStateWinsOverIndex() {
        // Staged as added, then edited again: the badge follows the edit you can
        // still see in the editor.
        let info = parse("1 AM N... 000000 100644 100644 000000 abc both.swift")
        #expect(info.change(at: "both.swift") == .modified)
    }

    @Test func deletedFileIsReported() {
        let info = parse("1 .D N... 100644 100644 000000 abc abc gone.txt")
        #expect(info.change(at: "gone.txt") == .deleted)
    }

    @Test func untrackedFile() {
        let info = parse("? scratch.txt")
        #expect(info.change(at: "scratch.txt") == .untracked)
    }

    /// git reports an untracked folder collapsed (`? build/`), so everything
    /// inside it has to inherit the state rather than looking clean.
    @Test func untrackedDirectoryCoversItsContents() {
        let info = parse("? build/")
        #expect(info.change(at: "build") == .untracked)
        #expect(info.change(at: "build/") == .untracked)
        #expect(info.change(at: "build/deep/nested/output.o") == .untracked)
        #expect(info.change(at: "buildings/other.txt") == nil)
    }

    // MARK: - Ignored paths

    @Test func ignoredEntriesAreDimmedButNotChanges() {
        let info = parse("! node_modules/")
        // An ignored path is not a change: it must not make the repo dirty, nor
        // carry a badge, nor light up its folders' roll-up dots.
        #expect(info.isDirty == false)
        #expect(info.change(at: "node_modules") == nil)
        #expect(info.directoryHasChanges(at: "node_modules") == false)
        #expect(info.isIgnored(at: "node_modules"))
    }

    /// `--ignored=traditional` collapses an ignored folder to one line instead of
    /// listing everything inside it, so descendants have to inherit.
    @Test func ignoredDirectoryCoversItsContents() {
        let info = parse("""
        ! node_modules/
        ! .env
        """)
        #expect(info.isIgnored(at: "node_modules/react/index.js"))
        #expect(info.isIgnored(at: ".env"))
        #expect(info.isIgnored(at: "src/app.swift") == false)
        // A near-miss sibling name isn't inside the ignored folder.
        #expect(info.isIgnored(at: "node_modules_local/x.js") == false)
    }

    @Test func ignoredAndChangedEntriesCoexist() {
        let info = parse("""
        1 .M N... 100644 100644 100644 abc abc src/app.swift
        ! build/
        """)
        #expect(info.isDirty)
        #expect(info.change(at: "src/app.swift") == .modified)
        #expect(info.isIgnored(at: "src/app.swift") == false)
        #expect(info.isIgnored(at: "build/out.o"))
        #expect(info.directoryHasChanges(at: "build") == false)
    }

    @Test func nothingIsIgnoredOutsideARepository() {
        #expect(GitStatusModel.Info().isIgnored(at: "/anything") == false)
    }

    @Test func renameBadgesTheNewPathOnly() {
        let info = parse(
            "2 R. N... 100644 100644 100644 abc abc R100 new/name.swift\told/name.swift"
        )
        #expect(info.change(at: "new/name.swift") == .renamed)
        // The old path is gone from disk, so it gets no row and no badge — but
        // the folder it left still counts as changed.
        #expect(info.change(at: "old/name.swift") == nil)
        #expect(info.directoryHasChanges(at: "old"))
        #expect(info.directoryHasChanges(at: "new"))
    }

    @Test func unmergedEntryIsAConflict() {
        let info = parse("u UU N... 100644 100644 100644 100644 h1 h2 h3 merge.txt")
        #expect(info.change(at: "merge.txt") == .conflicted)
    }

    @Test func changesRollUpThroughParentFolders() {
        let info = parse("1 .M N... 100644 100644 100644 abc abc a/b/c/deep.swift")
        #expect(info.directoryHasChanges(at: "a"))
        #expect(info.directoryHasChanges(at: "a/b"))
        #expect(info.directoryHasChanges(at: "a/b/c"))
        #expect(info.directoryHasChanges(at: "a/b/c/deep.swift") == false)
        #expect(info.directoryHasChanges(at: "z") == false)
    }

    @Test func pathsWithSpacesSurviveFieldSplitting() {
        let info = parse("""
        1 .M N... 100644 100644 100644 abc abc my docs/notes for later.md
        ? another file.txt
        """)
        #expect(info.change(at: "my docs/notes for later.md") == .modified)
        #expect(info.change(at: "another file.txt") == .untracked)
    }

    // MARK: - Absolute-path mapping

    @Test func repoRelativePathsMapOntoTheWorkspace() {
        // Workspace opened *below* the repo root, the case that makes naive
        // "root + relative" keys land on the wrong rows.
        let paths = GitStatusModel.PathMapper(
            repoRoot: URL(filePath: "/repo"),
            workspaceRoot: URL(filePath: "/repo/sub")
        )
        let info = parse("""
        1 .M N... 100644 100644 100644 abc abc sub/app.swift
        1 .M N... 100644 100644 100644 abc abc outside/other.swift
        """, paths: paths)

        #expect(info.change(at: "/repo/sub/app.swift") == .modified)
        #expect(info.change(at: "/repo/outside/other.swift") == .modified)
        #expect(info.directoryHasChanges(at: "/repo/sub"))
        // The roll-up stops at the workspace root; nothing above it has a row.
        #expect(info.directoryHasChanges(at: "/repo") == false)
    }

    @Test func mapperRebasesOntoTheWorkspacesOwnSpelling() throws {
        // `rev-parse --show-toplevel` prints a canonical path; the file tree keeps
        // the spelling the folder was opened with. A temp dir is the real case:
        // `/var/folders/…` for the tree, `/private/var/folders/…` from git.
        try TestSupport.withTempDir { dir in
            let treePath = dir.path(percentEncoded: false)
            try #require(treePath.hasPrefix("/var/"), "temp dirs are expected under the /var firmlink")
            let gitPath = "/private" + treePath

            let paths = GitStatusModel.PathMapper(repoRoot: URL(filePath: gitPath), workspaceRoot: dir)
            let info = parse("1 .M N... 100644 100644 100644 abc abc app.swift", paths: paths)
            #expect(info.change(at: dir.appending(path: "app.swift").path(percentEncoded: false)) == .modified)
        }
    }

    @Test func statesAreEmptyOutsideARepository() {
        let info = GitStatusModel.Info()
        #expect(info.change(at: "/anything.swift") == nil)
        #expect(info.directoryHasChanges(at: "/anything") == false)
    }

    // MARK: - C-quoted paths

    @Test func unquotesEscapedPaths() {
        // git C-quotes any path with special characters, whatever core.quotePath says.
        #expect(GitStatusModel.unquotePath("\"tab\\there.txt\"") == "tab\there.txt")
        #expect(GitStatusModel.unquotePath("\"say \\\"hi\\\".txt\"") == "say \"hi\".txt")
        #expect(GitStatusModel.unquotePath("\"back\\\\slash.txt\"") == "back\\slash.txt")
        // Multi-byte UTF-8 arrives as one octal escape per byte.
        #expect(GitStatusModel.unquotePath("\"caf\\303\\251.txt\"") == "café.txt")
        // Unquoted paths pass through untouched.
        #expect(GitStatusModel.unquotePath("plain.txt") == "plain.txt")
    }

    @Test func quotedEntryPathsAreDecoded() {
        let info = parse("? \"caf\\303\\251/menu.txt\"")
        #expect(info.change(at: "café/menu.txt") == .untracked)
    }
}
