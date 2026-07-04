import Testing
import Foundation
@testable import ibis

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
}
