import Foundation
import Observation

/// Drives project-wide search for a workspace: holds the query and options,
/// runs the (cancellable, off-main) search, and publishes results.
@MainActor
@Observable
final class ProjectSearchModel {
    var query = ""
    var caseSensitive = false
    var results: [SearchFileResult] = []
    var isSearching = false
    /// True once a search has completed for the current query, so the empty
    /// state only appears after real results (not during the debounce window).
    var hasSearched = false

    private var task: Task<Void, Never>?

    var totalMatches: Int {
        results.reduce(0) { $0 + $1.matches.count }
    }

    func run(root: URL) {
        task?.cancel()

        let query = self.query
        let caseSensitive = self.caseSensitive
        guard query.count >= 2 else {
            results = []
            isSearching = false
            hasSearched = false
            return
        }

        isSearching = true
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let found = ProjectSearch.search(
                root: root,
                query: query,
                caseSensitive: caseSensitive,
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.query == query, self.caseSensitive == caseSensitive else { return }
                self.results = found
                self.isSearching = false
                self.hasSearched = true
            }
        }
    }

    func clear() {
        task?.cancel()
        query = ""
        results = []
        isSearching = false
        hasSearched = false
    }

    /// Marks a search as imminent so the UI can show a spinner during debounce.
    func beginSearching() {
        if query.count >= 2 {
            isSearching = true
        } else {
            isSearching = false
            hasSearched = false
            results = []
        }
    }
}
