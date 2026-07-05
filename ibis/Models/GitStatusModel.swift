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
    nonisolated struct Info: Equatable {
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
            // A nil result means the probe was killed by the watchdog (indeterminate),
            // not that the folder stopped being a repo — keep the last-known status
            // rather than flashing "not a git repository" in the status bar.
            if let info { self.info = info }
        }
    }

    /// Runs `git status --porcelain=v2 --branch` and parses it. A clean non-zero
    /// exit (or missing `git`) means "not a repository"; `nil` means the probe was
    /// killed (e.g. the watchdog fired), so the caller should keep the old status.
    nonisolated private static func runStatus(root: URL) -> Info? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            // Neutralize repo-controlled config that lets `git status` execute a
            // command: opening an untrusted repo (e.g. an extracted archive with
            // a hostile `.git/config`) must not run its `core.fsmonitor` hook.
            "-c", "core.fsmonitor=",
            "-c", "core.untrackedCache=false",
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
        group.wait()

        // Killed by the watchdog (or any signal): status indeterminate, don't
        // report it as "not a repository".
        if timedOut.withLock({ $0 }) || process.terminationReason == .uncaughtSignal { return nil }
        guard process.terminationStatus == 0 else { return Info() }
        return parse(String(data: outData, encoding: .utf8) ?? "")
    }

    // `internal` (not `private`) so the porcelain parser can be unit-tested via
    // `@testable import` without spawning git.
    nonisolated static func parse(_ output: String) -> Info {
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
    nonisolated func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
