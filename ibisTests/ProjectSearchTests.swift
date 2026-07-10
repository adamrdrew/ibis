import Testing
import Foundation
@testable import Ibis

@Suite struct ProjectSearchTests {
    private static let notCancelled: @Sendable () -> Bool = { false }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func search(
        root: URL,
        query: String,
        caseSensitive: Bool = false,
        useRegex: Bool = false,
        wholeWord: Bool = false
    ) -> SearchResults {
        ProjectSearch.search(
            root: root,
            query: query,
            caseSensitive: caseSensitive,
            useRegex: useRegex,
            wholeWord: wholeWord,
            isCancelled: Self.notCancelled
        )
    }

    @Test func emptyQueryFindsNothing() throws {
        try TestSupport.withTempDir { dir in
            try write("hello world", to: dir.appending(path: "a.txt"))
            #expect(search(root: dir, query: "").files.isEmpty)
        }
    }

    @Test func findsSubstringMatchWithLineAndColumn() throws {
        try TestSupport.withTempDir { dir in
            try write("first line\nfind me here\nlast line", to: dir.appending(path: "a.txt"))
            let results = search(root: dir, query: "me")
            let file = try #require(results.files.first)
            let match = try #require(file.matches.first)
            #expect(match.lineNumber == 2)
            #expect(match.lineText == "find me here")
            #expect(match.matchColumnRange.location == 5)
            #expect(match.matchColumnRange.length == 2)
        }
    }

    @Test func caseSensitivityIsHonored() throws {
        try TestSupport.withTempDir { dir in
            try write("Hello\nhello", to: dir.appending(path: "a.txt"))
            #expect(search(root: dir, query: "hello", caseSensitive: false).files.first?.matches.count == 2)
            #expect(search(root: dir, query: "hello", caseSensitive: true).files.first?.matches.count == 1)
        }
    }

    @Test func wholeWordMatchesOnlyWordBoundaries() throws {
        try TestSupport.withTempDir { dir in
            try write("cat category concatenate", to: dir.appending(path: "a.txt"))
            let matches = search(root: dir, query: "cat", wholeWord: true).files.first?.matches
            #expect(matches?.count == 1)
        }
    }

    @Test func wholeWordMatchesQueriesWithNonWordEdges() throws {
        try TestSupport.withTempDir { dir in
            // One candidate per line (only the first match per line is
            // reported). `\b` beside a non-word character can never match, so
            // these queries used to return zero results.
            try write("let x = foo() + 1\ncall myfoo() now\n$state here\nrecount -count count", to: dir.appending(path: "a.txt"))

            let foo = search(root: dir, query: "foo()", wholeWord: true).files.first?.matches
            #expect(foo?.count == 1)
            #expect(foo?.first?.lineNumber == 1) // myfoo() is still excluded

            let state = search(root: dir, query: "$state", wholeWord: true).files.first?.matches
            #expect(state?.count == 1)

            let count = search(root: dir, query: "-count", wholeWord: true).files.first?.matches
            #expect(count?.count == 1)
            #expect(count?.first?.matchColumnRange.location == 8)
        }
    }

    @Test func regexMatches() throws {
        try TestSupport.withTempDir { dir in
            try write("foo123\nbar\nbaz456", to: dir.appending(path: "a.txt"))
            let results = search(root: dir, query: "[a-z]+[0-9]+", useRegex: true)
            #expect(results.files.first?.matches.count == 2)
        }
    }

    @Test func invalidRegexIsReported() throws {
        try TestSupport.withTempDir { dir in
            try write("anything", to: dir.appending(path: "a.txt"))
            let results = search(root: dir, query: "(unclosed", useRegex: true)
            #expect(results.summary.invalidPattern)
            #expect(results.files.isEmpty)
        }
    }

    @Test func ignoredDirectoriesAreSkipped() throws {
        try TestSupport.withTempDir { dir in
            let nodeModules = dir.appending(path: "node_modules")
            try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
            try write("needle", to: nodeModules.appending(path: "dep.js"))
            try write("needle", to: dir.appending(path: "src.js"))
            let results = search(root: dir, query: "needle")
            #expect(results.files.count == 1)
            #expect(results.files.first?.url.lastPathComponent == "src.js")
        }
    }

    @Test func binaryFilesAreSkipped() throws {
        try TestSupport.withTempDir { dir in
            var bytes = Data("nee".utf8)
            bytes.append(0) // NUL byte marks it binary
            bytes.append(Data("dle".utf8))
            try bytes.write(to: dir.appending(path: "blob.bin"))
            try write("needle", to: dir.appending(path: "text.txt"))
            let results = search(root: dir, query: "needle")
            #expect(results.files.count == 1)
            #expect(results.files.first?.url.lastPathComponent == "text.txt")
        }
    }

    @Test func searchingASingleFileRoot() throws {
        try TestSupport.withTempDir { dir in
            let file = dir.appending(path: "only.txt")
            try write("match here", to: file)
            let results = search(root: file, query: "match")
            #expect(results.summary.scannedFiles == 1)
            #expect(results.files.first?.matches.count == 1)
        }
    }

    // MARK: Re-anchoring a result against a live (possibly edited) buffer

    private func makeMatch(lineText: String, column: NSRange, absolute: NSRange) -> SearchMatch {
        SearchMatch(lineNumber: 1, lineText: lineText, matchColumnRange: column, characterRange: absolute)
    }

    @Test func resolvedSelectionKeepsAStillValidRange() {
        let content = "aaa\nfind me\n" as NSString
        let match = makeMatch(lineText: "find me", column: NSRange(location: 5, length: 2), absolute: NSRange(location: 9, length: 2))
        #expect(ProjectSearch.resolvedSelection(for: match, in: content) == NSRange(location: 9, length: 2))
    }

    @Test func resolvedSelectionReanchorsAfterEditsAboveTheMatch() {
        // Three lines inserted above shift every offset; the stale range now
        // covers "\nf". The nearest occurrence of the matched text wins.
        let content = "x\ny\nz\naaa\nfind me\n" as NSString
        let match = makeMatch(lineText: "find me", column: NSRange(location: 5, length: 2), absolute: NSRange(location: 9, length: 2))
        #expect(ProjectSearch.resolvedSelection(for: match, in: content) == NSRange(location: 15, length: 2))
    }

    @Test func resolvedSelectionPicksTheNearestOfSeveralOccurrences() {
        let content = "me ... me ... me" as NSString // offsets 0, 7, 14
        let match = makeMatch(lineText: "xx me xx", column: NSRange(location: 3, length: 2), absolute: NSRange(location: 8, length: 2))
        #expect(ProjectSearch.resolvedSelection(for: match, in: content) == NSRange(location: 7, length: 2))
    }

    @Test func resolvedSelectionFallsBackToACaretWhenTheTextIsGone() {
        let content = "nothing to see" as NSString
        let match = makeMatch(lineText: "find me", column: NSRange(location: 5, length: 2), absolute: NSRange(location: 40, length: 2))
        // Selecting whatever now sits at the stale offsets would highlight
        // arbitrary text; a clamped caret is the honest fallback.
        #expect(ProjectSearch.resolvedSelection(for: match, in: content) == NSRange(location: 14, length: 0))
    }
}
