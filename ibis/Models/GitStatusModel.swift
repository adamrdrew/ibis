import Foundation
import Observation
import os

/// Live Git status for a workspace root, shown in the status bar. Reads state by
/// shelling out to `git` (the app is unsandboxed) and is refreshed whenever the
/// workspace's file-system watcher reports a change, so branch/dirty/ahead-behind
/// update the instant Git does.
@Observable
@MainActor
final class GitStatusModel {
    /// What Git has to say about one path, as decorated in the file browser.
    /// Staged and unstaged states collapse to a single verdict — the sidebar has
    /// room for one letter, and the working-tree state is the one that matters
    /// when you're looking at the file you just edited.
    nonisolated enum FileChange: Equatable {
        case untracked, added, modified, deleted, renamed, conflicted

        /// The one-letter badge shown at the trailing edge of the row.
        var letter: String {
            switch self {
            case .untracked: "U"
            case .added: "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            case .conflicted: "!"
            }
        }

        var label: String {
            switch self {
            case .untracked: "Untracked"
            case .added: "Added"
            case .modified: "Modified"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .conflicted: "Merge conflict"
            }
        }

        /// The porcelain status code for one side (index or working tree).
        static func from(code: Character) -> FileChange? {
            switch code {
            case "A": .added
            case "C": .added // a copy is a new file as far as the tree is concerned
            case "M", "T": .modified
            case "D": .deleted
            case "R": .renamed
            case "U": .conflicted
            default: nil
            }
        }
    }

    nonisolated struct Info: Equatable {
        var isRepository = false
        var branch: String?
        var head: String?
        var isDetached = false
        var isDirty = false
        var hasUpstream = false
        var ahead = 0
        var behind = 0

        /// Per-file state, keyed by absolute path (see ``PathMapper``). Only
        /// changed paths appear; everything else is committed and clean.
        var fileStates: [String: FileChange] = [:]
        /// Untracked *folders*: `git status` reports these collapsed (`? build/`)
        /// rather than listing every file inside, so descendants inherit.
        var untrackedDirectories: Set<String> = []
        /// Folders with a change somewhere beneath them, for the roll-up dot.
        var dirtyDirectories: Set<String> = []
        /// Paths `.gitignore` excludes, shown dimmed. Ignored folders are
        /// reported collapsed (`! node_modules/`) like untracked ones, so
        /// descendants inherit rather than being listed one by one.
        var ignoredPaths: Set<String> = []
        var ignoredDirectories: Set<String> = []

        var shortHead: String? { head.map { String($0.prefix(7)) } }
        var isSynced: Bool { hasUpstream && ahead == 0 && behind == 0 }

        /// The badge for a file-browser row, or nil when the path is clean or
        /// this isn't a repository.
        func change(at path: String) -> FileChange? {
            guard isRepository else { return nil }
            let key = path.strippingTrailingSlashes
            if let change = fileStates[key] { return change }
            return inherits(key, from: untrackedDirectories) ? .untracked : nil
        }

        /// Whether a folder contains a change (at any depth), for the roll-up dot.
        func directoryHasChanges(at path: String) -> Bool {
            isRepository && dirtyDirectories.contains(path.strippingTrailingSlashes)
        }

        /// Whether the path is excluded by `.gitignore` — itself, or by sitting
        /// inside an ignored folder.
        func isIgnored(at path: String) -> Bool {
            guard isRepository else { return false }
            let key = path.strippingTrailingSlashes
            return ignoredPaths.contains(key) || inherits(key, from: ignoredDirectories)
        }

        /// Whether any ancestor folder of `path` is in `directories`.
        private func inherits(_ path: String, from directories: Set<String>) -> Bool {
            guard !directories.isEmpty else { return false }
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "/" {
                if directories.contains(parent) { return true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }
    }

    /// Maps the repo-root-relative paths git prints onto the absolute paths the
    /// file tree is keyed by. Two things have to line up: the workspace can sit
    /// *below* the repo root (opening a subfolder of a repo), and the two sides
    /// may spell the same folder differently — `rev-parse --show-toplevel`
    /// returns a fully canonical path (`/var/…` → `/private/var/…`) while the
    /// tree keeps whatever spelling the folder was opened with. So both roots are
    /// canonicalized for comparison, and anything inside the workspace is rebased
    /// onto the workspace's own spelling — the one `FileNode.url` uses.
    nonisolated struct PathMapper: Equatable {
        let repoRoot: String
        let workspaceRoot: String
        private let canonicalRepoRoot: String
        private let canonicalWorkspaceRoot: String

        init(repoRoot: URL, workspaceRoot: URL) {
            self.repoRoot = repoRoot.path(percentEncoded: false).strippingTrailingSlashes
            self.workspaceRoot = workspaceRoot.path(percentEncoded: false).strippingTrailingSlashes
            self.canonicalRepoRoot = Self.canonical(self.repoRoot)
            self.canonicalWorkspaceRoot = Self.canonical(self.workspaceRoot)
        }

        /// Every absolute spelling a tree row might use for a repo-relative path,
        /// each paired with the workspace root it hangs off (where the folder
        /// roll-up stops). Two are possible because the tree mixes them:
        /// `FileNode.url` for the root is whatever the folder was opened with,
        /// while `contentsOfDirectory(at:)` hands back canonicalized children.
        func spellings(of relative: String) -> [(path: String, root: String)] {
            let canonical = canonicalRepoRoot + "/" + relative
            var result = [(path: canonical, root: canonicalWorkspaceRoot)]
            guard workspaceRoot != canonicalWorkspaceRoot else { return result }

            if canonical == canonicalWorkspaceRoot {
                result.append((path: workspaceRoot, root: workspaceRoot))
            } else if canonical.hasPrefix(canonicalWorkspaceRoot + "/") {
                result.append((
                    path: workspaceRoot + canonical.dropFirst(canonicalWorkspaceRoot.count),
                    root: workspaceRoot
                ))
            }
            return result
        }

        /// `realpath(3)`, the only spelling both sides agree on. `URL`'s
        /// `resolvingSymlinksInPath()` is not a substitute: it leaves macOS
        /// firmlinks such as `/var` → `/private/var` alone, which is exactly the
        /// difference git's output introduces. Paths that don't exist (a deleted
        /// file, a unit-test fixture) canonicalize to themselves.
        private static func canonical(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private(set) var info = Info()
    let root: URL
    private var task: Task<Void, Never>?

    /// When the ignore set was last computed, so it can be refreshed on a slow
    /// cadence (see ``ignoreProbeInterval``).
    private var lastIgnoreProbe: ContinuousClock.Instant?

    /// How stale the ignore set may get. Asking git for ignored paths makes the
    /// probe roughly ten times more expensive (it has to walk the working tree
    /// rather than just consult the index), and this refresh runs on every
    /// filesystem event — including the build output churning inside the very
    /// folders that are ignored. What's ignored changes only when `.gitignore`
    /// is edited or a new path appears, so a few seconds of lag on the dimming
    /// costs nothing, while branch and dirty state stay instant.
    private static let ignoreProbeInterval: Duration = .seconds(5)

    init(root: URL) {
        self.root = root
    }

    /// Recomputes Git status off the main actor, cancelling any in-flight refresh.
    ///
    /// The probe runs on a GCD queue, NOT `Task.detached`: `runStatus` blocks
    /// (`waitUntilExit`, pipe drains), and blocking a *cooperative-pool* thread
    /// is how CI deadlocked — on a small runner the pool has only a few
    /// threads, and two wedged git probes starved the entire concurrency
    /// runtime (no test task could ever be scheduled again). GCD global-queue
    /// threads may block; the pool over-subscribes.
    func refresh() {
        task?.cancel()
        let root = self.root
        let now = ContinuousClock.now
        let includeIgnored = lastIgnoreProbe.map { now - $0 >= Self.ignoreProbeInterval } ?? true
        // Carried across cheap refreshes so dimmed rows don't blink back to
        // normal between ignore probes.
        let knownIgnored = (paths: info.ignoredPaths, directories: info.ignoredDirectories)
        task = Task {
            let info = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: Self.runStatus(root: root, includeIgnored: includeIgnored)
                    )
                }
            }
            if Task.isCancelled { return }
            // A nil result means the probe was killed by the watchdog (indeterminate),
            // not that the folder stopped being a repo — keep the last-known status
            // rather than flashing "not a git repository" in the status bar.
            guard var info else { return }
            if includeIgnored {
                lastIgnoreProbe = now
            } else if info.isRepository {
                info.ignoredPaths = knownIgnored.paths
                info.ignoredDirectories = knownIgnored.directories
            }
            self.info = info
        }
    }

    /// Runs `git status --porcelain=v2 --branch` and parses it. A clean non-zero
    /// exit (or missing `git`) means "not a repository"; `nil` means the probe was
    /// killed (e.g. the watchdog fired), so the caller should keep the old status.
    nonisolated private static func runStatus(root: URL, includeIgnored: Bool) -> Info? {
        // `--ignored` (traditional mode) reports an ignored *folder* collapsed to
        // one line instead of listing everything inside it, so a repo with a
        // huge `node_modules` costs one entry, not thousands. It's still the
        // expensive half of the probe, hence the caller's throttle.
        var arguments = ["status", "--porcelain=v2", "--branch"]
        if includeIgnored { arguments.append("--ignored=traditional") }
        guard let status = runGit(arguments, root: root) else {
            return nil // indeterminate — keep the last-known status
        }
        guard status.code == 0 else { return Info() }
        // Porcelain paths are relative to the repo *top level*, which isn't
        // necessarily the folder that was opened, so ask where that is. Cheap
        // next to `status`; if it fails, file states are simply left unmapped
        // (no badges) rather than being attached to the wrong rows.
        var mapper: PathMapper?
        if let top = runGit(["rev-parse", "--show-toplevel"], root: root), top.code == 0 {
            let path = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                mapper = PathMapper(repoRoot: URL(filePath: path), workspaceRoot: root)
            }
        }
        return parse(status.output, paths: mapper)
    }

    /// Runs `git` in `root`, returning its exit code and stdout — or `nil` if the
    /// invocation was killed (watchdog, signal) and its result is indeterminate.
    nonisolated private static func runGit(
        _ arguments: [String],
        root: URL
    ) -> (code: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            // Neutralize repo-controlled config that lets `git status` execute a
            // command: opening an untrusted repo (e.g. an extracted archive with
            // a hostile `.git/config`) must not run its `core.fsmonitor` hook.
            "-c", "core.fsmonitor=",
            "-c", "core.untrackedCache=false",
            // Print UTF-8 paths as-is; anything genuinely special is still
            // C-quoted, and `unquotePath` undoes that.
            "-c", "core.quotePath=false",
            "-C", root.path(percentEncoded: false),
        ] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return (code: 127, output: "") // no git on disk — "not a repository"
        }
        // Written by the watchdog on a background queue and read after
        // `waitUntilExit` — needs a real synchronization boundary, not a plain
        // captured var (that read/write race is undefined behavior).
        let timedOut = OSAllocatedUnfairLock(initialState: false)

        // Drain both pipes concurrently: if git writes a lot to stderr (many
        // `warning:` lines) while we only read stdout, it can block on a full
        // stderr pipe and never close stdout, hanging the reader forever.
        let group = DispatchGroup()
        var outData = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Bound a git that hangs (e.g. blocked on an index lock) so slow/stuck
        // invocations during an FSEvents storm can't pile up indefinitely.
        let watchdog = DispatchWorkItem {
            // `cancel()` below can't stop an already-running work item, so don't
            // signal a process that has since exited (and possibly had its pid
            // recycled by the kernel).
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        // Bounded, not `group.wait()`: EOF on the pipes can lag the child's
        // exit indefinitely when a concurrently spawned process (a PTY shell,
        // another git) inherits the write ends before spawn marks them
        // close-on-exec — the drain then blocks until that unrelated process
        // dies. Give the drains a beat, then declare the probe indeterminate;
        // the abandoned drain threads release themselves whenever EOF arrives.
        guard group.wait(timeout: .now() + 5) == .success else { return nil }

        // Killed by the watchdog (or any signal): status indeterminate, don't
        // report it as "not a repository".
        if timedOut.withLock({ $0 }) || process.terminationReason == .uncaughtSignal { return nil }
        return (code: process.terminationStatus, output: String(data: outData, encoding: .utf8) ?? "")
    }

    /// Parses `git status --porcelain=v2 --branch` output. `internal` (not
    /// `private`) so the parser can be unit-tested via `@testable import`
    /// without spawning git.
    ///
    /// `paths` maps git's repo-relative paths onto the file tree's absolute
    /// paths; without it the per-file states stay repo-relative (which is what
    /// the parser tests assert against).
    nonisolated static func parse(_ output: String, paths: PathMapper? = nil) -> Info {
        var info = Info(isRepository: true)

        /// Records one changed path under every spelling the tree might use for
        /// it, and marks its folder chain as containing a change. A nil `change`
        /// contributes only the folder roll-up — that's a path a rename moved
        /// *away from*, which no longer exists on disk to carry a badge.
        func markChanged(_ relative: String, as change: FileChange?) {
            info.isDirty = true
            let isDirectory = relative.hasSuffix("/")
            // Without a mapper (the parser's own tests) paths stay repo-relative.
            let spellings: [(path: String, root: String?)] = paths.map { mapper in
                mapper.spellings(of: relative).map { (path: $0.path, root: $0.root) }
            } ?? [(path: relative, root: nil)]

            for spelling in spellings {
                let path = spelling.path.strippingTrailingSlashes
                if let change {
                    info.fileStates[path] = change
                    if isDirectory, change == .untracked {
                        info.untrackedDirectories.insert(path)
                    }
                }
                // Roll the change up the folder chain, stopping at the workspace
                // root — rows above it don't exist in the tree.
                var parent = (path as NSString).deletingLastPathComponent
                while !parent.isEmpty, parent != "/" {
                    if let root = spelling.root,
                       parent != root, !parent.hasPrefix(root + "/") { break }
                    info.dirtyDirectories.insert(parent)
                    if parent == spelling.root { break }
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }

        /// Records an ignored path. Deliberately *not* routed through
        /// `markChanged`: an ignored file is not a change, so it must not make
        /// the repo dirty or light up its folders' roll-up dots.
        func markIgnored(_ relative: String) {
            let isDirectory = relative.hasSuffix("/")
            let spellings = paths.map { $0.spellings(of: relative).map(\.path) } ?? [relative]
            for spelling in spellings {
                let path = spelling.strippingTrailingSlashes
                info.ignoredPaths.insert(path)
                if isDirectory { info.ignoredDirectories.insert(path) }
            }
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let value = line.dropPrefix("# branch.oid ") {
                info.head = String(value)
            } else if let value = line.dropPrefix("# branch.head ") {
                if value == "(detached)" {
                    info.isDetached = true
                } else {
                    info.branch = String(value)
                }
            } else if line.dropPrefix("# branch.upstream ") != nil {
                info.hasUpstream = true
            } else if let value = line.dropPrefix("# branch.ab ") {
                for part in value.split(separator: " ") {
                    if part.hasPrefix("+") { info.ahead = Int(part.dropFirst()) ?? 0 }
                    else if part.hasPrefix("-") { info.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                parseEntry(line, markChanged: markChanged, markIgnored: markIgnored)
            }
        }
        return info
    }

    /// Parses one `git status --porcelain=v2` entry. The formats, with a
    /// fixed field count before a path that may itself contain spaces:
    ///
    ///     1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
    ///     2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<origPath>
    ///     u <xy> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
    ///     ? <path>
    ///     ! <path>
    nonisolated private static func parseEntry(
        _ line: Substring,
        markChanged: (String, FileChange?) -> Void,
        markIgnored: (String) -> Void
    ) {
        /// The path is everything after the first `fields` space-separated
        /// fields, so a name with spaces survives intact.
        func tail(after fields: Int) -> String? {
            let parts = line.split(separator: " ", maxSplits: fields, omittingEmptySubsequences: false)
            guard parts.count == fields + 1 else { return nil }
            return String(parts[fields])
        }

        switch line.first {
        case "?":
            guard let path = tail(after: 1) else { return }
            markChanged(unquotePath(path), .untracked)
        case "!":
            guard let path = tail(after: 1) else { return }
            markIgnored(unquotePath(path))
        case "1":
            guard let path = tail(after: 8), let change = change(inField: line) else { return }
            markChanged(unquotePath(path), change)
        case "2":
            // The new name comes first; the old one is gone from disk, so it
            // only contributes its folder to the roll-up.
            guard let both = tail(after: 9) else { return }
            let halves = both.split(separator: "\t", maxSplits: 1)
            guard let new = halves.first else { return }
            markChanged(unquotePath(String(new)), change(inField: line) ?? .renamed)
            if halves.count == 2 { markChanged(unquotePath(String(halves[1])), nil) }
        case "u":
            guard let path = tail(after: 10) else { return }
            markChanged(unquotePath(path), .conflicted)
        default:
            return
        }
    }

    /// The verdict for an entry's `<XY>` field: the working-tree side when it
    /// has one (that's the edit you can still see), else the staged side.
    nonisolated private static func change(inField line: Substring) -> FileChange? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        let xy = parts[1]
        guard xy.count == 2, let staged = xy.first, let worktree = xy.last else { return nil }
        return FileChange.from(code: worktree) ?? FileChange.from(code: staged)
    }

    /// Undoes the C-style quoting git applies to paths with special characters
    /// (always, regardless of `core.quotePath`): the whole path is wrapped in
    /// double quotes and backslash escapes stand in for the offending bytes.
    nonisolated static func unquotePath(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 else { return path }
        let body = path.dropFirst().dropLast()
        var bytes: [UInt8] = []
        var iterator = body.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        while let scalar = pending ?? iterator.next() {
            pending = nil
            guard scalar == "\\" else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
                continue
            }
            guard let escape = iterator.next() else { break }
            switch escape {
            case "n": bytes.append(0x0A)
            case "t": bytes.append(0x09)
            case "r": bytes.append(0x0D)
            case "a": bytes.append(0x07)
            case "b": bytes.append(0x08)
            case "f": bytes.append(0x0C)
            case "v": bytes.append(0x0B)
            case "\\", "\"": bytes.append(UInt8(escape.value))
            case "0"..."7":
                // A three-digit octal byte; UTF-8 arrives one escaped byte at a
                // time, so collecting bytes (not scalars) reassembles it.
                var value = Int(String(escape), radix: 8) ?? 0
                var digits = 1
                while digits < 3, let next = iterator.next() {
                    guard let digit = Int(String(next), radix: 8), next.value < 0x38 else {
                        pending = next
                        break
                    }
                    value = value * 8 + digit
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default:
                bytes.append(contentsOf: Array(String(escape).utf8))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension Substring {
    /// Returns the remainder after `prefix`, or nil if the string doesn't start with it.
    nonisolated func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
