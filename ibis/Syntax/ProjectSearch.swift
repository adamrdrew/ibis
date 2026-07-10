import Foundation

/// One match within a file: the line it's on, the line's text, the column range
/// of the match (for preview highlighting), and the absolute character range
/// (for selecting when opened).
nonisolated struct SearchMatch: Identifiable, Sendable {
    let id = UUID()
    let lineNumber: Int
    let lineText: String
    let matchColumnRange: NSRange
    let characterRange: NSRange
}

/// All matches found within a single file.
nonisolated struct SearchFileResult: Identifiable, Sendable {
    let url: URL
    let matches: [SearchMatch]
    var id: URL { url }
}

/// Whether the search stopped short of a full scan, so the UI can say so.
nonisolated struct SearchSummary: Sendable {
    var scannedFiles = 0
    var hitFileLimit = false
    var hitMatchLimit = false
    var skippedLargeFiles = 0
    var invalidPattern = false

    var isLimited: Bool { hitFileLimit || hitMatchLimit || skippedLargeFiles > 0 }
}

/// The full outcome of a search: the file results plus a summary of any caps hit.
nonisolated struct SearchResults: Sendable {
    var files: [SearchFileResult] = []
    var summary = SearchSummary()
}

/// Recursive project search (plain substring, whole-word, or regex). Runs off
/// the main actor, skips noise directories, oversized files, and binaries, and
/// honors a cancellation check plus result caps so huge trees stay responsive.
nonisolated enum ProjectSearch {
    private static let ignoredDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "build", "dist",
        "DerivedData", ".next", ".nuxt", ".idea", ".venv", "venv", "__pycache__",
        ".gradle", "Pods", ".terraform"
    ]

    private static let maxFiles = 500
    private static let maxMatches = 5000
    /// Files larger than this are skipped (and counted) rather than read whole.
    private static let maxFileSize = 2 * 1024 * 1024
    /// Regex matching is skipped on lines longer than this: a user-supplied
    /// pattern like `(a+)+$` backtracks catastrophically on a long minified line,
    /// pinning a thread for minutes. Substring matching has no such limit.
    private static let maxRegexLineLength = 5000

    private enum Matcher {
        case substring(String, NSString.CompareOptions)
        case regex(NSRegularExpression)
    }

    nonisolated static func search(
        root: URL,
        query: String,
        caseSensitive: Bool,
        useRegex: Bool,
        wholeWord: Bool,
        isCancelled: @Sendable () -> Bool
    ) -> SearchResults {
        guard !query.isEmpty else { return SearchResults() }

        guard let matcher = makeMatcher(query: query, caseSensitive: caseSensitive, useRegex: useRegex, wholeWord: wholeWord) else {
            var summary = SearchSummary()
            summary.invalidPattern = true
            return SearchResults(files: [], summary: summary)
        }

        var summary = SearchSummary()
        let fileManager = FileManager.default

        let rootIsDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !rootIsDirectory {
            let matches = fileMatches(at: root, matcher: matcher)
            summary.scannedFiles = matches == nil ? 0 : 1
            let files = (matches?.isEmpty == false) ? [SearchFileResult(url: root, matches: matches!)] : []
            return SearchResults(files: files, summary: summary)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return SearchResults(files: [], summary: summary)
        }

        var results: [SearchFileResult] = []
        var totalMatches = 0

        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { break }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory ?? false {
                if ignoredDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Only read regular files. A named pipe (FIFO) — which shows up in
            // some build trees — would otherwise block in open/read until a
            // writer appears, and the blocked syscall ignores cancellation,
            // pinning the search task forever.
            guard values?.isRegularFile ?? false else { continue }

            if url.lastPathComponent == ".DS_Store" { continue }
            if let size = values?.fileSize, size > maxFileSize {
                summary.skippedLargeFiles += 1
                continue
            }

            guard let matches = fileMatches(at: url, matcher: matcher) else { continue }
            summary.scannedFiles += 1
            guard !matches.isEmpty else { continue }

            results.append(SearchFileResult(url: url, matches: matches))
            totalMatches += matches.count
            if results.count >= maxFiles { summary.hitFileLimit = true; break }
            if totalMatches >= maxMatches { summary.hitMatchLimit = true; break }
        }

        return SearchResults(files: results, summary: summary)
    }

    // MARK: - Re-anchoring a result against a live buffer

    /// The selection to use when opening `match` in a document whose buffer may
    /// have diverged from disk (unsaved edits shift every offset below them).
    /// If the stored range still covers the matched text it's used as-is;
    /// otherwise the occurrence of the matched text *nearest* the original
    /// location wins, and if the text is gone entirely the caret just lands at
    /// the (clamped) original location with nothing selected — selecting
    /// whatever now occupies the stale offsets would highlight arbitrary text.
    static func resolvedSelection(for match: SearchMatch, in content: NSString) -> NSRange {
        let stored = match.characterRange
        let line = match.lineText as NSString
        guard NSMaxRange(match.matchColumnRange) <= line.length else {
            return NSRange(location: min(stored.location, content.length), length: 0)
        }
        let matched = line.substring(with: match.matchColumnRange)

        if NSMaxRange(stored) <= content.length, content.substring(with: stored) == matched {
            return stored
        }

        var best: NSRange?
        var from = 0
        while from < content.length {
            let found = content.range(
                of: matched, options: [],
                range: NSRange(location: from, length: content.length - from)
            )
            guard found.location != NSNotFound else { break }
            if let current = best,
               abs(current.location - stored.location) <= abs(found.location - stored.location) {
                // Occurrences only get farther away from here on.
                break
            }
            best = found
            from = found.location + max(found.length, 1)
        }
        return best ?? NSRange(location: min(stored.location, content.length), length: 0)
    }

    // MARK: - Matcher construction

    /// Builds the line matcher, or returns `nil` for an invalid regex. Whole-word
    /// is a regex over the escaped literal with `\b` added only on the sides that
    /// begin/end with a word character — `\b` next to a non-word character (as in
    /// `foo()`, `$state`, `-count`) can never match at a natural token boundary,
    /// which made such queries return zero results.
    private static func makeMatcher(query: String, caseSensitive: Bool, useRegex: Bool, wholeWord: Bool) -> Matcher? {
        let regexOptions: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        if useRegex {
            guard let regex = try? NSRegularExpression(pattern: query, options: regexOptions) else { return nil }
            return .regex(regex)
        }
        if wholeWord {
            let leading = isWordCharacter(query.unicodeScalars.first) ? "\\b" : ""
            let trailing = isWordCharacter(query.unicodeScalars.last) ? "\\b" : ""
            let pattern = leading + NSRegularExpression.escapedPattern(for: query) + trailing
            if let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) {
                return .regex(regex)
            }
        }
        return .substring(query, caseSensitive ? [] : [.caseInsensitive])
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - Per-file matching

    /// Returns the matches in a file, or `nil` if it's unreadable or binary
    /// (NUL byte in the first 8 KB). Reads only an 8 KB prefix for the binary
    /// check before reading the whole file.
    private static func fileMatches(at url: URL, matcher: Matcher) -> [SearchMatch]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let prefix = (try? handle.read(upToCount: 8192)) ?? Data()
        try? handle.close()
        if prefix.contains(0) { return nil }

        guard let data = try? Data(contentsOf: url) else { return nil }
        return matches(in: String(decoding: data, as: UTF8.self), matcher: matcher)
    }

    private static func matches(in content: String, matcher: Matcher) -> [SearchMatch] {
        let fullString = content as NSString
        var found: [SearchMatch] = []
        var lineNumber = 0

        fullString.enumerateSubstrings(
            in: NSRange(location: 0, length: fullString.length),
            options: [.byLines]
        ) { line, lineRange, _, stop in
            lineNumber += 1
            // Cancellation can't interrupt a blocked syscall, but it can abandon a
            // huge file promptly (search runs inside a cancellable Task).
            if lineNumber % 512 == 0, Task.isCancelled { stop.pointee = true; return }
            guard let line else { return }
            let lineString = line as NSString
            let columnRange: NSRange
            switch matcher {
            case .substring(let query, let options):
                columnRange = lineString.range(of: query, options: options)
            case .regex(let regex):
                // Skip pathologically long lines to bound regex backtracking.
                guard lineString.length <= maxRegexLineLength else { return }
                columnRange = regex.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: lineString.length)
                )?.range ?? NSRange(location: NSNotFound, length: 0)
            }
            guard columnRange.location != NSNotFound, columnRange.length > 0 else { return }

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
