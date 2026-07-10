#if canImport(SwiftMCP)
import Testing
import Foundation
@testable import Ibis

/// Lifecycle integration for the embedded MCP server: binds a real listener on
/// 127.0.0.1 with an ephemeral port. Serialized: the controller is a singleton.
@MainActor
@Suite(.serialized) struct MCPServerControllerTests {
    @Test func startBindsAnEphemeralPortAndStopReleasesIt() async throws {
        let controller = MCPServerController.shared
        #expect(controller.isRunning == false)

        controller.start(preferredPort: 0)
        let started = await TestSupport.waitUntil(timeout: 15) { controller.isRunning }
        #expect(started, "expected the MCP server to come up on an ephemeral port")
        #expect(controller.activePort > 0)
        #expect(controller.startError == nil)
        #expect(MCPService.runningPort == controller.activePort)

        // Starting again while running is a no-op (same port).
        let boundPort = controller.activePort
        controller.start(preferredPort: 0)
        #expect(controller.activePort == boundPort)

        controller.stop()
        #expect(controller.isRunning == false)
        #expect(controller.activePort == 0)
        #expect(MCPService.runningPort == nil)
        // Give the listener a beat to actually release before other tests run.
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func serviceIsCompiledIn() {
        #expect(MCPService.isAvailable)
    }

    @Test func agentOrientationEmbedsSafelyInSingleQuotes() {
        // launchCommand wraps this in single quotes; an apostrophe would truncate
        // the shell argument mid-prompt.
        #expect(!MCPService.agentOrientation.contains("'"))
        #expect(!MCPService.agentOrientation.contains("\""))
    }

    @Test func launchCommandPinsSessionIdOnFreshClaudeLaunch() async {
        TestSupport.withIsolatedDefaults {
            let settings = AppSettings()
            settings.agentCommand = "claude"
            settings.agentArgs = ""
            settings.agentKind = .claude
            settings.agentInjectSystemPrompt = false // isolate the session flag

            let sid = UUID().uuidString
            let command = MCPService.launchCommand(settings: settings, sessionID: sid)
            #expect(command == "claude --session-id " + sid)
        }
    }

    @Test func launchCommandKeepsSystemPromptOnResume() async {
        TestSupport.withIsolatedDefaults {
            let settings = AppSettings()
            settings.agentCommand = "claude"
            settings.agentArgs = ""
            settings.agentKind = .claude
            settings.mcpEnabled = true
            // --append-system-prompt is per-invocation (Claude doesn't store it
            // in the session), so resuming must re-inject it like a fresh launch.
            settings.agentInjectSystemPrompt = true

            let sid = UUID().uuidString
            let command = MCPService.launchCommand(settings: settings, sessionID: sid, resume: true)
            #expect(command?.hasPrefix("claude --resume " + sid) == true)
            #expect(command?.contains("--append-system-prompt") == true)
        }
    }

    @Test func launchCommandRejectsMalformedSessionIDs() async {
        TestSupport.withIsolatedDefaults {
            let settings = AppSettings()
            settings.agentCommand = "claude"
            settings.agentArgs = ""
            settings.agentKind = .claude
            settings.agentInjectSystemPrompt = false

            // Session ids come back from persisted UserDefaults and are
            // interpolated into a `shell -c` string: anything but a UUID —
            // above all shell metacharacters — must never reach the command.
            for hostile in ["x; rm -rf ~", "$(open /tmp)", "abc", ""] {
                #expect(MCPService.launchCommand(settings: settings, sessionID: hostile) == "claude")
                #expect(MCPService.launchCommand(settings: settings, sessionID: hostile, resume: true) == "claude")
            }
        }
    }

    @Test func launchCommandIgnoresSessionForNonClaudeAgent() async {
        TestSupport.withIsolatedDefaults {
            let settings = AppSettings()
            settings.agentCommand = "codex"
            settings.agentArgs = ""
            settings.agentKind = .codex

            let sid = UUID().uuidString
            #expect(MCPService.launchCommand(settings: settings, sessionID: sid) == "codex")
            #expect(MCPService.launchCommand(settings: settings, sessionID: sid, resume: true) == "codex")
        }
    }

    @Test func claudeProjectSlugMatchesClaudeCodesRule() {
        // Claude Code names each project directory by replacing every character
        // outside [a-zA-Z0-9] with "-".
        #expect(MCPService.claudeProjectSlug(for: URL(filePath: "/Users/a/Development/my-proj"))
                == "-Users-a-Development-my-proj")
        #expect(MCPService.claudeProjectSlug(for: URL(filePath: "/Users/a/my.proj"))
                == "-Users-a-my-proj")
        // Trailing slashes don't appear in Claude's cwd, so they must not
        // produce a trailing "-".
        #expect(MCPService.claudeProjectSlug(for: URL(filePath: "/tmp/foo/"))
                == "-tmp-foo")
        // Claude's replacement runs per UTF-16 code unit (a JS regex without
        // the `u` flag), so a non-BMP character — a surrogate pair — becomes
        // TWO dashes. (Accented BMP characters are deliberately not asserted:
        // URL(filePath:) decomposes them (NFD), so the dash count depends on
        // normalization — one more reason claudeSessionFileExists doesn't
        // trust the slug alone and falls back to scanning.)
        #expect(MCPService.claudeProjectSlug(for: URL(filePath: "/tmp/📁proj"))
                == "-tmp---proj")
    }

    @Test func claudeSessionFileExistsFindsATranscript() throws {
        // Point at a unique fake project; the slug directory lives under the
        // real ~/.claude/projects (that's where the function looks), created
        // and removed by this test.
        let project = URL(filePath: "/tmp/ibis-slug-test-\(UUID().uuidString)")
        let sid = UUID().uuidString
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: ".claude", "projects", MCPService.claudeProjectSlug(for: project))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!MCPService.claudeSessionFileExists(sessionID: sid, workingDirectory: project))
        try Data().write(to: dir.appendingPathComponent(sid).appendingPathExtension("jsonl"))
        #expect(MCPService.claudeSessionFileExists(sessionID: sid, workingDirectory: project))
    }

    @Test func claudeSessionFileExistsFallsBackToScanningProjects() throws {
        // Claude truncates + hash-suffixes long slugs and its naming rule is an
        // undocumented internal, so the transcript can live under a directory
        // whose name Ibis can't predict. Existence checking must still find it:
        // session UUIDs are unique, so a scan of ~/.claude/projects suffices.
        let project = URL(filePath: "/tmp/ibis-scan-test-\(UUID().uuidString)")
        let sid = UUID().uuidString
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: ".claude", "projects", "ibis-test-unrelated-slug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent(sid).appendingPathExtension("jsonl"))

        #expect(MCPService.claudeSessionFileExists(sessionID: sid, workingDirectory: project))
    }

    @Test func agentRelaunchCommandPicksResumeOrRePin() async throws {
        try TestSupport.withIsolatedDefaults {
            let settings = AppSettings()
            settings.agentCommand = "claude"
            settings.agentArgs = ""
            settings.agentKind = .claude
            settings.agentInjectSystemPrompt = false

            let project = URL(filePath: "/tmp/ibis-relaunch-test-\(UUID().uuidString)")
            let sid = UUID().uuidString
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appending(components: ".claude", "projects", MCPService.claudeProjectSlug(for: project))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            // No transcript yet (the session was never messaged): re-pin the id.
            let pinned = MCPService.agentRelaunchCommand(settings: settings, sessionID: sid, workingDirectory: project)
            #expect(pinned?.resume == false)
            #expect(pinned?.command == "claude --session-id " + sid)

            // Transcript on disk: the conversation exists, so resume it.
            try Data().write(to: dir.appendingPathComponent(sid).appendingPathExtension("jsonl"))
            let resumed = MCPService.agentRelaunchCommand(settings: settings, sessionID: sid, workingDirectory: project)
            #expect(resumed?.resume == true)
            #expect(resumed?.command == "claude --resume " + sid)
        }
    }
}
#endif
