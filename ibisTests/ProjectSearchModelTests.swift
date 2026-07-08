import Testing
import Foundation
@testable import Ibis

@MainActor
@Suite struct ProjectSearchModelTests {
    @Test func shortQueryClearsWithoutSearching() throws {
        try TestSupport.withTempDir { root in
            let model = ProjectSearchModel()
            model.query = "a"
            model.run(root: root)
            #expect(model.results.isEmpty)
            #expect(model.isSearching == false)
            #expect(model.hasSearched == false)
        }
    }

    @Test func findsMatchesAndReportsCompletion() async throws {
        try await TestSupport.withTempDir { root in
            try "let needle = 1\nlet other = 2\nneedle again".write(
                to: root.appending(path: "code.swift"), atomically: true, encoding: .utf8
            )
            let model = ProjectSearchModel()
            model.query = "needle"
            model.run(root: root)

            let finished = await TestSupport.waitUntil { model.hasSearched }
            #expect(finished)
            #expect(model.isSearching == false)
            #expect(model.totalMatches == 2)
            #expect(model.results.first?.matches.first?.lineNumber == 1)
        }
    }

    @Test func staleResultsAreDroppedWhenTheQueryChanges() async throws {
        try await TestSupport.withTempDir { root in
            try "match me".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
            let model = ProjectSearchModel()
            model.query = "match"
            model.run(root: root)
            // Change the query before the search lands: its results must not apply.
            model.query = "different"
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.hasSearched == false)
            #expect(model.results.isEmpty)
        }
    }

    @Test func clearResetsEverything() async throws {
        try await TestSupport.withTempDir { root in
            try "abc".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
            let model = ProjectSearchModel()
            model.query = "abc"
            model.run(root: root)
            _ = await TestSupport.waitUntil { model.hasSearched }

            model.clear()
            #expect(model.query.isEmpty)
            #expect(model.results.isEmpty)
            #expect(model.isSearching == false)
            #expect(model.hasSearched == false)
            #expect(model.totalMatches == 0)
        }
    }

    @Test func beginSearchingOnlySpinsForRealQueries() {
        let model = ProjectSearchModel()
        model.query = "ab"
        model.beginSearching()
        #expect(model.isSearching)

        model.query = "a"
        model.beginSearching()
        #expect(model.isSearching == false)
        #expect(model.hasSearched == false)
    }
}
