import Foundation

/// One match within a file: the line it's on, the line's text, the column range
/// of the match (for preview highlighting), and the absolute character range
/// (for selecting when opened).
struct SearchMatch: Identifiable, Sendable {
    let id = UUID()
    let lineNumber: Int
    let lineText: String
    let matchColumnRange: NSRange
    let characterRange: NSRange
}

/// All matches found within a single file.
struct SearchFileResult: Identifiable, Sendable {
    let url: URL
    let matches: [SearchMatch]
    var id: URL { url }
}

/// Recursive, plain-substring project search. Runs off the main actor, skips
/// noise directories and binary files, and honors a cancellation check plus
/// result caps so huge trees stay responsive.
enum ProjectSearch {
    private static let ignoredDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "build", "dist",
        "DerivedData", ".next", ".nuxt", ".idea", ".venv", "venv", "__pycache__",
        ".gradle", "Pods", ".terraform"
    ]

    private static let maxFiles = 500
    private static let maxMatches = 5000

    nonisolated static func search(
        root: URL,
        query: String,
        caseSensitive: Bool,
        isCancelled: @Sendable () -> Bool
    ) -> [SearchFileResult] {
        guard !query.isEmpty else { return [] }
        let fileManager = FileManager.default

        let rootIsDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !rootIsDirectory {
            let matches = matches(in: root, query: query, caseSensitive: caseSensitive)
            return matches.isEmpty ? [] : [SearchFileResult(url: root, matches: matches)]
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        var results: [SearchFileResult] = []
        var totalMatches = 0

        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { break }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if ignoredDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            if url.lastPathComponent == ".DS_Store" { continue }

            let fileMatches = matches(in: url, query: query, caseSensitive: caseSensitive)
            guard !fileMatches.isEmpty else { continue }

            results.append(SearchFileResult(url: url, matches: fileMatches))
            totalMatches += fileMatches.count
            if results.count >= maxFiles || totalMatches >= maxMatches { break }
        }

        return results
    }

    // MARK: - Per-file matching

    private static func matches(in url: URL, query: String, caseSensitive: Bool) -> [SearchMatch] {
        guard let data = try? Data(contentsOf: url),
              !data.prefix(8000).contains(0) else { return [] }
        let content = String(decoding: data, as: UTF8.self)
        return matches(in: content, query: query, caseSensitive: caseSensitive)
    }

    static func matches(in content: String, query: String, caseSensitive: Bool) -> [SearchMatch] {
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let fullString = content as NSString
        var found: [SearchMatch] = []
        var lineNumber = 0

        fullString.enumerateSubstrings(
            in: NSRange(location: 0, length: fullString.length),
            options: [.byLines]
        ) { line, lineRange, _, _ in
            lineNumber += 1
            guard let line else { return }
            let lineString = line as NSString
            let columnRange = lineString.range(of: query, options: options)
            guard columnRange.location != NSNotFound else { return }

            let absolute = NSRange(
                location: lineRange.location + columnRange.location,
                length: columnRange.length
            )
            found.append(
                SearchMatch(
                    lineNumber: lineNumber,
                    lineText: line,
                    matchColumnRange: columnRange,
                    characterRange: absolute
                )
            )
        }

        return found
    }
}
