import Testing
import Foundation
@testable import ibis

/// Integration tests for the `git status` probe (`refresh()`), the seam the
/// parser tests deliberately skip. Spawns the real `/usr/bin/git` against
/// throwaway repos.
@MainActor
@Suite struct GitStatusIntegrationTests {
    /// Runs git in `dir` with a hermetic identity, failing the test on error.
    private func git(_ arguments: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", dir.path(percentEncoded: false),
            "-c", "user.name=ibis-tests",
            "-c", "user.email=tests@ibis.local",
            "-c", "commit.gpgsign=false",
        ] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private func refreshAndWait(_ model: GitStatusModel, until condition: @escaping (GitStatusModel.Info) -> Bool) async -> Bool {
        model.refresh()
        return await TestSupport.waitUntil { condition(model.info) }
    }

    @Test func nonRepositoryReportsNotARepo() async throws {
        try await TestSupport.withTempDir { dir in
            let model = GitStatusModel(root: dir)
            #expect(model.info.isRepository == false) // initial state
            model.refresh()
            // Wait for the probe to land; it must still say "not a repository".
            try await Task.sleep(for: .milliseconds(500))
            #expect(model.info.isRepository == false)
        }
    }

    @Test func freshCommitShowsCleanBranch() async throws {
        try await TestSupport.withTempDir { dir in
            try git(["init", "-b", "main"], in: dir)
            try "hello".write(to: dir.appending(path: "f.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: dir)
            try git(["commit", "-m", "initial"], in: dir)

            let model = GitStatusModel(root: dir)
            let settled = await refreshAndWait(model) { $0.isRepository }
            #expect(settled)
            #expect(model.info.branch == "main")
            #expect(model.info.isDirty == false)
            #expect(model.info.isDetached == false)
            #expect(model.info.head != nil)
            #expect(model.info.shortHead?.count == 7)
            #expect(model.info.hasUpstream == false)
        }
    }

    @Test func modifiedFileShowsDirty() async throws {
        try await TestSupport.withTempDir { dir in
            try git(["init", "-b", "main"], in: dir)
            try "v1".write(to: dir.appending(path: "f.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: dir)
            try git(["commit", "-m", "initial"], in: dir)
            try "v2".write(to: dir.appending(path: "f.txt"), atomically: true, encoding: .utf8)

            let model = GitStatusModel(root: dir)
            let settled = await refreshAndWait(model) { $0.isRepository && $0.isDirty }
            #expect(settled)
        }
    }

    @Test func detachedHeadIsReported() async throws {
        try await TestSupport.withTempDir { dir in
            try git(["init", "-b", "main"], in: dir)
            try "x".write(to: dir.appending(path: "f.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: dir)
            try git(["commit", "-m", "one"], in: dir)
            try git(["checkout", "--detach", "HEAD"], in: dir)

            let model = GitStatusModel(root: dir)
            let settled = await refreshAndWait(model) { $0.isRepository && $0.isDetached }
            #expect(settled)
            #expect(model.info.branch == nil)
        }
    }
}
