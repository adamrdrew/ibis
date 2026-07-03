import Foundation
import Observation

/// Live Git status for a workspace root, shown in the status bar. Reads state by
/// shelling out to `git` (the app is unsandboxed) and is refreshed whenever the
/// workspace's file-system watcher reports a change, so branch/dirty/ahead-behind
/// update the instant Git does.
@Observable
@MainActor
final class GitStatusModel {
    struct Info: Equatable {
        var isRepository = false
        var branch: String?
        var head: String?
        var isDetached = false
        var isDirty = false
        var hasUpstream = false
        var ahead = 0
        var behind = 0

        var shortHead: String? { head.map { String($0.prefix(7)) } }
        var isSynced: Bool { hasUpstream && ahead == 0 && behind == 0 }
    }

    private(set) var info = Info()
    let root: URL
    private var task: Task<Void, Never>?

    init(root: URL) {
        self.root = root
    }

    /// Recomputes Git status off the main actor, cancelling any in-flight refresh.
    func refresh() {
        task?.cancel()
        let root = self.root
        task = Task {
            let info = await Task.detached(priority: .utility) {
                Self.runStatus(root: root)
            }.value
            if Task.isCancelled { return }
            self.info = info
        }
    }

    /// Runs `git status --porcelain=v2 --branch` and parses it. A non-zero exit
    /// (or missing `git`) means "not a repository".
    nonisolated private static func runStatus(root: URL) -> Info {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", root.path(percentEncoded: false),
            "status", "--porcelain=v2", "--branch",
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return Info()
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        _ = err.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else { return Info() }
        return parse(String(data: data, encoding: .utf8) ?? "")
    }

    nonisolated private static func parse(_ output: String) -> Info {
        var info = Info(isRepository: true)
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
                info.isDirty = true
            }
        }
        return info
    }
}

private extension Substring {
    /// Returns the remainder after `prefix`, or nil if the string doesn't start with it.
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
