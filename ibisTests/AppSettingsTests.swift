import Testing
import Foundation
@testable import ibis

/// AppSettings persists through the standard `UserDefaults`, so every test
/// snapshots the keys it may touch. Serialized: process-wide defaults.
@MainActor
@Suite(.serialized) struct AppSettingsTests {
    private static let settingsKeys = [
        "editor.fontName", "editor.fontSize", "editor.tabWidth", "editor.usesSoftTabs",
        "editor.showLineNumbers", "editor.wordWrap", "editor.lightTheme", "editor.darkTheme",
        "terminal.fontName", "terminal.fontSize", "terminal.shellPath",
        "terminal.dockHeight", "terminal.dockWidth", "terminal.placement",
        "agent.name", "agent.command", "agent.args", "agent.kind",
        "mcp.enabled", "mcp.port", "mcp.token",
    ]

    @Test func freshDefaultsProduceSaneSettings() {
        TestSupport.withPreservedDefaults(Self.settingsKeys) {
            let settings = AppSettings()
            #expect(settings.fontName == "SF Mono")
            #expect(settings.fontSize == 13)
            #expect(settings.tabWidth == 4)
            #expect(settings.usesSoftTabs)
            #expect(settings.showLineNumbers)
            #expect(settings.wordWrap == false)
            #expect(settings.terminalPlacement == .bottom)
            #expect(settings.agentKind == .claude)
            #expect(settings.mcpEnabled == false)
            // Ephemeral port by default (no squattable fixed port).
            #expect(settings.mcpPort == 0)
        }
    }

    @Test func changesPersistAcrossInstances() {
        TestSupport.withPreservedDefaults(Self.settingsKeys) {
            let first = AppSettings()
            first.fontSize = 15
            first.terminalPlacement = .trailing
            first.agentKind = .codex

            let second = AppSettings()
            #expect(second.fontSize == 15)
            #expect(second.terminalPlacement == .trailing)
            #expect(second.agentKind == .codex)
        }
    }

    @Test func mcpTokenIsGeneratedOnceAndRoundTrips() {
        TestSupport.withPreservedDefaults(Self.settingsKeys) {
            let first = AppSettings()
            let token = first.mcpToken
            #expect(!token.isEmpty)
            // A second load sees the same token, not a fresh one.
            #expect(AppSettings().mcpToken == token)
        }
    }

    @Test func freshTokensAreURLSafeAndUnique() {
        let a = AppSettings.freshToken()
        let b = AppSettings.freshToken()
        #expect(a != b)
        let urlSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(a.unicodeScalars.allSatisfy { urlSafe.contains($0) })
        #expect(a.count >= 32) // 24 bytes → 32 base64url chars
    }

    @Test func agentCommandLineComposesCommandAndArgs() {
        TestSupport.withPreservedDefaults(Self.settingsKeys) {
            let settings = AppSettings()
            settings.agentCommand = "claude"
            settings.agentArgs = ""
            #expect(settings.agentCommandLine == "claude")

            settings.agentArgs = "  --continue  "
            #expect(settings.agentCommandLine == "claude --continue")

            settings.agentCommand = "   "
            #expect(settings.agentCommandLine == nil)
        }
    }

    @Test func agentKindsHaveDistinctDisplayNames() {
        let names = AgentKind.allCases.map(\.displayName)
        #expect(Set(names).count == AgentKind.allCases.count)
        #expect(AgentKind.claude.displayName == "Claude Code")
    }

    // MARK: MCPService.launchCommand

    @Test func launchCommandIsNilWithoutAnAgent() {
        TestSupport.withPreservedDefaults(Self.settingsKeys) {
            let settings = AppSettings()
            settings.agentCommand = ""
            #expect(MCPService.launchCommand(settings: settings) == nil)
        }
    }

    @Test func launchCommandPassesThroughWhenMCPIsOff() {
        TestSupport.withPreservedDefaults(Self.settingsKeys) {
            let settings = AppSettings()
            settings.agentCommand = "claude"
            settings.mcpEnabled = false
            #expect(MCPService.launchCommand(settings: settings) == "claude")
        }
    }

    @Test func launchCommandPassesThroughForNonClaudeAgents() {
        TestSupport.withPreservedDefaults(Self.settingsKeys) {
            let settings = AppSettings()
            settings.agentCommand = "codex"
            settings.agentKind = .codex
            settings.mcpEnabled = true
            #expect(MCPService.launchCommand(settings: settings) == "codex")
        }
    }

    @Test func launchCommandInjectsOrientationForClaudeWithMCP() throws {
        try TestSupport.withPreservedDefaults(Self.settingsKeys) {
            let settings = AppSettings()
            settings.agentCommand = "claude"
            settings.agentKind = .claude
            settings.mcpEnabled = true
            let command = try #require(MCPService.launchCommand(settings: settings))
            #expect(command.hasPrefix("claude --append-system-prompt '"))
            #expect(command.hasSuffix("'"))
            // The prompt is wrapped in single quotes, so it must contain none
            // itself: exactly the two delimiters.
            #expect(command.filter { $0 == "'" }.count == 2)
            #expect(command.contains("running inside Ibis"))
        }
    }
}
