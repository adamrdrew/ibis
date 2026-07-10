import Testing
import Foundation
@testable import Ibis

@Suite struct MCPConfigWriterTests {
    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func permissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func gitignore(in root: URL) -> String {
        (try? String(contentsOf: root.appending(path: ".gitignore"), encoding: .utf8)) ?? ""
    }

    @Test func serverURLPointsAtLoopbackMCPEndpoint() {
        #expect(MCPConfigWriter.serverURL(port: 8123) == "http://127.0.0.1:8123/mcp")
    }

    // MARK: Claude (.mcp.json)

    @Test func claudeWriteReferencesTheTokenViaEnvVar() throws {
        try TestSupport.withTempDir { root in
            let result = try MCPConfigWriter.write(agent: .claude, projectRoot: root, port: 4000, token: "tok123")
            let file = root.appending(path: ".mcp.json")
            #expect(result.path == file)

            let object = try json(at: file)
            let servers = try #require(object["mcpServers"] as? [String: Any])
            let ibis = try #require(servers["ibis"] as? [String: Any])
            #expect(ibis["type"] as? String == "http")
            // .mcp.json is Claude's project-shared config — teams commit it, and
            // gitignore can't protect an already-tracked file. The secret AND
            // the machine/launch-specific port stay out of the file (Claude
            // expands ${VAR} at load), so the same bytes work on every machine
            // and never go stale…
            #expect(ibis["url"] as? String == "http://127.0.0.1:${IBIS_MCP_PORT}/mcp")
            #expect((ibis["headers"] as? [String: String])?["Authorization"] == "Bearer ${IBIS_MCP_TOKEN}")
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(!contents.contains("tok123"))
            #expect(!contents.contains("4000"))
            // …and the live values are surfaced in the message for external shells.
            #expect(result.message.contains("tok123"))
            #expect(result.message.contains("4000"))
            // A secret-free file must not be gitignored: teams commit it.
            #expect(!gitignore(in: root).contains(".mcp.json"))
        }
    }

    @Test func customAgentUsesTheClaudeFormat() throws {
        try TestSupport.withTempDir { root in
            _ = try MCPConfigWriter.write(agent: .custom, projectRoot: root, port: 4000, token: "t")
            #expect(FileManager.default.fileExists(atPath: root.appending(path: ".mcp.json").path))
        }
    }

    @Test func claudeWritePreservesOtherServersAndUnknownKeys() throws {
        try TestSupport.withTempDir { root in
            let existing = #"{"mcpServers": {"other": {"type": "stdio", "command": "other-mcp"}}, "custom": true}"#
            try existing.write(to: root.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)

            _ = try MCPConfigWriter.write(agent: .claude, projectRoot: root, port: 4000, token: "t")
            let object = try json(at: root.appending(path: ".mcp.json"))
            let servers = try #require(object["mcpServers"] as? [String: Any])
            #expect(servers["other"] != nil)
            #expect(servers["ibis"] != nil)
            #expect(object["custom"] as? Bool == true)
        }
    }

    @Test func rewriteReplacesTheIbisEntryInPlace() throws {
        try TestSupport.withTempDir { root in
            _ = try MCPConfigWriter.write(agent: .claude, projectRoot: root, port: 4000, token: "old")
            _ = try MCPConfigWriter.write(agent: .claude, projectRoot: root, port: 5000, token: "new")
            let object = try json(at: root.appending(path: ".mcp.json"))
            let servers = try #require(object["mcpServers"] as? [String: Any])
            #expect(servers.count == 1)
            let ibis = try #require(servers["ibis"] as? [String: Any])
            #expect(ibis["url"] as? String == "http://127.0.0.1:${IBIS_MCP_PORT}/mcp")
            #expect((ibis["headers"] as? [String: String])?["Authorization"] == "Bearer ${IBIS_MCP_TOKEN}")
        }
    }

    @Test func unparseableExistingConfigAbortsInsteadOfClobbering() throws {
        try TestSupport.withTempDir { root in
            let file = root.appending(path: ".mcp.json")
            try "not json {".write(to: file, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) {
                _ = try MCPConfigWriter.write(agent: .claude, projectRoot: root, port: 4000, token: "t")
            }
            // The user's file is untouched.
            #expect(try String(contentsOf: file, encoding: .utf8) == "not json {")
        }
    }

    @Test func gitignoreAppendIsIdempotentAndAdditive() throws {
        try TestSupport.withTempDir { root in
            // Antigravity's config still carries the raw token, so it is still
            // gitignored (Claude's no longer holds a secret and isn't).
            try "node_modules/\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
            _ = try MCPConfigWriter.write(agent: .antigravity, projectRoot: root, port: 1, token: "t")
            _ = try MCPConfigWriter.write(agent: .antigravity, projectRoot: root, port: 2, token: "t")
            let contents = gitignore(in: root)
            #expect(contents.hasPrefix("node_modules/\n"))
            #expect(contents.components(separatedBy: "\n").filter { $0 == ".agents/mcp_config.json" }.count == 1)
        }
    }

    // MARK: Antigravity (.agents/mcp_config.json)

    @Test func antigravityWritesWorkspaceConfig() throws {
        try TestSupport.withTempDir { root in
            _ = try MCPConfigWriter.write(agent: .antigravity, projectRoot: root, port: 7777, token: "agtok")
            let file = root.appending(path: ".agents/mcp_config.json")
            let object = try json(at: file)
            let servers = try #require(object["mcpServers"] as? [String: Any])
            let ibis = try #require(servers["ibis"] as? [String: Any])
            #expect(ibis["serverUrl"] as? String == "http://127.0.0.1:7777/mcp")
            #expect((ibis["headers"] as? [String: String])?["Authorization"] == "Bearer agtok")
            #expect(try permissions(of: file) == 0o600)
            #expect(gitignore(in: root).contains(".agents/mcp_config.json"))
        }
    }

    @Test func antigravityRefusesToWriteASecretIntoATrackedConfig() throws {
        try TestSupport.withTempDir { root in
            // A tracked config can't be protected by .gitignore — the write
            // must refuse rather than stage the token for the next push.
            let dir = root.appending(path: ".agents")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"mcpServers": {}}"#.write(to: dir.appending(path: "mcp_config.json"), atomically: true, encoding: .utf8)
            try git(["init", "-q"], in: root)
            try git(["add", ".agents/mcp_config.json"], in: root)

            #expect(throws: (any Error).self) {
                _ = try MCPConfigWriter.write(agent: .antigravity, projectRoot: root, port: 1, token: "secret")
            }
            let contents = try String(contentsOf: dir.appending(path: "mcp_config.json"), encoding: .utf8)
            #expect(!contents.contains("secret"))
        }
    }

    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path(percentEncoded: false)] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    // MARK: Codex (.codex/config.toml)

    @Test func codexWritesTOMLWithEnvVarToken() throws {
        try TestSupport.withTempDir { root in
            let result = try MCPConfigWriter.write(agent: .codex, projectRoot: root, port: 9000, token: "cxtok")
            let toml = try String(contentsOf: root.appending(path: ".codex/config.toml"), encoding: .utf8)
            #expect(toml.contains("[mcp_servers.ibis]"))
            #expect(toml.contains(#"url = "http://127.0.0.1:9000/mcp""#))
            // Codex reads the token from the environment, never inline.
            #expect(toml.contains(#"bearer_token_env_var = "IBIS_MCP_TOKEN""#))
            #expect(!toml.contains("cxtok"))
            // …so the user must be told the value somewhere: the result message.
            #expect(result.message.contains("cxtok"))
        }
    }

    @Test func codexReplacesItsTableButKeepsOthers() throws {
        try TestSupport.withTempDir { root in
            let dir = root.appending(path: ".codex")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = """
            [general]
            model = "gpt"

            [mcp_servers.ibis]
            url = "http://127.0.0.1:1/mcp"
            stale = true

            [mcp_servers.other]
            url = "http://example.com"
            """
            try existing.write(to: dir.appending(path: "config.toml"), atomically: true, encoding: .utf8)

            _ = try MCPConfigWriter.write(agent: .codex, projectRoot: root, port: 4242, token: "t")
            let toml = try String(contentsOf: dir.appending(path: "config.toml"), encoding: .utf8)
            #expect(toml.contains(#"model = "gpt""#))
            #expect(toml.contains("[mcp_servers.other]"))
            #expect(toml.contains(#"url = "http://127.0.0.1:4242/mcp""#))
            // The stale table body was replaced, not merged.
            #expect(!toml.contains("stale = true"))
            #expect(!toml.contains("http://127.0.0.1:1/mcp"))
        }
    }

    @Test func commentedOutCodexTableIsNotTreatedAsPresent() throws {
        try TestSupport.withTempDir { root in
            let dir = root.appending(path: ".codex")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = """
            # [mcp_servers.ibis]
            # url = "http://127.0.0.1:1/mcp"
            """
            try existing.write(to: dir.appending(path: "config.toml"), atomically: true, encoding: .utf8)

            // A substring check saw the commented header as "present": the
            // adoption offer was suppressed forever and writes silently no-op'd
            // while reporting success.
            #expect(MCPConfigWriter.projectState(agent: .codex, projectRoot: root) == .missingIbis)

            _ = try MCPConfigWriter.write(agent: .codex, projectRoot: root, port: 4242, token: "t")
            let toml = try String(contentsOf: dir.appending(path: "config.toml"), encoding: .utf8)
            // The comment survives and a real table was appended.
            #expect(toml.contains("# [mcp_servers.ibis]"))
            #expect(toml.components(separatedBy: "\n").contains("[mcp_servers.ibis]"))
            #expect(toml.contains(#"url = "http://127.0.0.1:4242/mcp""#))
            #expect(MCPConfigWriter.projectState(agent: .codex, projectRoot: root) == .ibisPresent)
        }
    }

    // MARK: hardenExistingConfigs

    @Test func hardenFixesPermissionsOnTokenBearingConfigs() throws {
        try TestSupport.withTempDir { root in
            let file = root.appending(path: ".mcp.json")
            let config = #"{"mcpServers": {"ibis": {"type": "http", "url": "u", "headers": {"Authorization": "Bearer secret"}}}}"#
            try config.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

            MCPConfigWriter.hardenExistingConfigs(projectRoot: root)
            #expect(try permissions(of: file) == 0o600)
            #expect(gitignore(in: root).contains(".mcp.json"))
        }
    }

    @Test func hardenLeavesEnvVarReferencesAlone() throws {
        try TestSupport.withTempDir { root in
            // The new-style config carries no secret — hardening must not
            // chmod or gitignore it (teams commit .mcp.json).
            let file = root.appending(path: ".mcp.json")
            let config = #"{"mcpServers": {"ibis": {"type": "http", "url": "u", "headers": {"Authorization": "Bearer ${IBIS_MCP_TOKEN}"}}}}"#
            try config.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

            MCPConfigWriter.hardenExistingConfigs(projectRoot: root)
            #expect(try permissions(of: file) == 0o644)
            #expect(!gitignore(in: root).contains(".mcp.json"))
        }
    }

    @Test func hardenLeavesTokenlessConfigsAlone() throws {
        try TestSupport.withTempDir { root in
            // A hand-written config with no Ibis token may be deliberately
            // committed; hardening must not gitignore or chmod it.
            let file = root.appending(path: ".mcp.json")
            let config = #"{"mcpServers": {"other": {"type": "stdio", "command": "x"}}}"#
            try config.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

            MCPConfigWriter.hardenExistingConfigs(projectRoot: root)
            #expect(try permissions(of: file) == 0o644)
            #expect(!gitignore(in: root).contains(".mcp.json"))
        }
    }
}
