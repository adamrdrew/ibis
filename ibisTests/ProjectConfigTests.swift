import Testing
import Foundation
@testable import ibis

@MainActor
@Suite struct ProjectConfigTests {
    // MARK: - Empty / default state

    @Test func absentFileYieldsEmptyConfig() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            #expect(config.actions.isEmpty)
            #expect(config.envVars.isEmpty)
            #expect(config.loadError == nil)
            #expect(config.hasExecutableContent == false)
        }
    }

    // MARK: - Blocked env keys

    @Test(arguments: [
        ("DYLD_INSERT_LIBRARIES", true),
        ("dyld_anything", true),
        ("LD_PRELOAD", true),
        ("LD_LIBRARY_PATH", true),
        ("HOME", true),
        ("ZDOTDIR", true),
        ("XDG_CONFIG_HOME", true),
        ("PATH", false),
        ("API_KEY", false),
    ])
    func blockedEnvKeyDetection(key: String, blocked: Bool) {
        #expect(ProjectConfig.isBlockedEnvKey(key) == blocked)
    }

    @Test func environmentDropsBlockedBlankAndTrimsKeys() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.envVars = [
                ProjectConfig.EnvVar(key: "PATH ", value: "/x"),   // trailing space trimmed
                ProjectConfig.EnvVar(key: "   ", value: "y"),       // blank -> dropped
                ProjectConfig.EnvVar(key: "LD_PRELOAD", value: "z"), // blocked -> dropped
                ProjectConfig.EnvVar(key: "FOO", value: "bar"),
            ]
            let env = config.environment
            #expect(env == ["PATH": "/x", "FOO": "bar"])
        }
    }

    @Test func runnableActionsFilterOutIncompleteEntries() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.actions = [
                ProjectConfig.Action(name: "Build", command: "make"),
                ProjectConfig.Action(name: "", command: "orphan"),
                ProjectConfig.Action(name: "NoCommand", command: "   "),
            ]
            #expect(config.runnableActions.count == 1)
            #expect(config.runnableActions.first?.name == "Build")
            #expect(config.hasExecutableContent)
        }
    }

    // MARK: - Persistence

    @Test func saveThenReloadRoundTrips() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.actions = [ProjectConfig.Action(name: "Test", command: "swift test")]
            config.envVars = [ProjectConfig.EnvVar(key: "API_ENV", value: "staging")]
            try config.save()

            let reloaded = ProjectConfig(root: dir)
            #expect(reloaded.loadError == nil)
            #expect(reloaded.actions.first?.name == "Test")
            #expect(reloaded.actions.first?.command == "swift test")
            #expect(reloaded.environment["API_ENV"] == "staging")
        }
    }

    @Test func saveWritesFileAndGitignoresIt() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.actions = [ProjectConfig.Action(name: "Run", command: "./run.sh")]
            try config.save()

            #expect(FileManager.default.fileExists(atPath: dir.appending(path: ".ibis.json").path(percentEncoded: false)))
            let gitignore = try String(contentsOf: dir.appending(path: ".gitignore"), encoding: .utf8)
            #expect(gitignore.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == ".ibis.json" })
        }
    }

    @Test func blockedEnvKeysAreNotPersisted() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.envVars = [
                ProjectConfig.EnvVar(key: "DYLD_INSERT_LIBRARIES", value: "/evil.dylib"),
                ProjectConfig.EnvVar(key: "SAFE", value: "1"),
            ]
            try config.save()
            let raw = try String(contentsOf: dir.appending(path: ".ibis.json"), encoding: .utf8)
            #expect(raw.contains("DYLD_INSERT_LIBRARIES") == false)
            #expect(raw.contains("SAFE"))
        }
    }

    @Test func malformedFileSetsLoadErrorAndBlocksSave() throws {
        try TestSupport.withTempDir { dir in
            try "{ not valid json".write(to: dir.appending(path: ".ibis.json"), atomically: true, encoding: .utf8)
            let config = ProjectConfig(root: dir)
            #expect(config.loadError != nil)
            #expect(throws: (any Error).self) { try config.save() }
        }
    }

    @Test func unreadableFileSetsLoadErrorAndBlocksSave() throws {
        try TestSupport.withTempDir { dir in
            let file = dir.appending(path: ".ibis.json")
            try #"{"env": {"REAL": "config"}}"#.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

            let config = ProjectConfig(root: dir)
            #expect(config.loadError != nil)
            // Saving must refuse rather than replace the user's real (unreadable) file.
            #expect(throws: (any Error).self) { try config.save() }
        }
    }

    @Test func laterDuplicateEnvKeysWin() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.envVars = [
                ProjectConfig.EnvVar(key: "DUP", value: "first"),
                ProjectConfig.EnvVar(key: "DUP", value: "second"),
            ]
            #expect(config.environment == ["DUP": "second"])
        }
    }

    @Test func unknownTopLevelKeysSurviveASaveRoundTrip() throws {
        try TestSupport.withTempDir { dir in
            let original = #"{"env": {"A": "1"}, "futureSetting": {"nested": true}}"#
            try original.write(to: dir.appending(path: ".ibis.json"), atomically: true, encoding: .utf8)

            let config = ProjectConfig(root: dir)
            config.envVars.append(ProjectConfig.EnvVar(key: "B", value: "2"))
            try config.save()

            let raw = try String(contentsOf: dir.appending(path: ".ibis.json"), encoding: .utf8)
            #expect(raw.contains("futureSetting"))
            #expect(raw.contains("\"B\""))
        }
    }

    @Test func savedConfigIsOwnerOnly() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.envVars = [ProjectConfig.EnvVar(key: "SECRET", value: "s3cret")]
            try config.save()
            let attrs = try FileManager.default.attributesOfItem(
                atPath: dir.appending(path: ".ibis.json").path(percentEncoded: false)
            )
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func savingAnEmptyConfigRemovesTheSections() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.envVars = [ProjectConfig.EnvVar(key: "A", value: "1")]
            config.actions = [ProjectConfig.Action(name: "N", command: "c")]
            try config.save()

            config.envVars = []
            config.actions = []
            try config.save()
            let raw = try String(contentsOf: dir.appending(path: ".ibis.json"), encoding: .utf8)
            #expect(!raw.contains("\"env\""))
            #expect(!raw.contains("\"actions\""))
        }
    }
}
