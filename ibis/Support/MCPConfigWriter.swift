import Foundation

/// Writes (or merges) the Ibis MCP server entry into the current project's
/// config file, in the format expected by the user's chosen agent. All agents
/// point at the same Streamable HTTP endpoint (`/mcp`) with a bearer token.
enum MCPConfigWriter {
    struct Result {
        let path: URL
        let message: String
    }

    static func serverURL(port: Int) -> String { "http://127.0.0.1:\(port)/mcp" }

    static func write(agent: AgentKind, projectRoot: URL, port: Int, token: String) throws -> Result {
        switch agent {
        case .claude, .custom:
            return try writeClaude(root: projectRoot, port: port, token: token)
        case .antigravity:
            return try writeAntigravity(root: projectRoot, port: port, token: token)
        case .codex:
            return try writeCodex(root: projectRoot, port: port, token: token)
        }
    }

    // MARK: Claude Code — .mcp.json (project root)

    private static func writeClaude(root: URL, port: Int, token: String) throws -> Result {
        let file = root.appending(path: ".mcp.json")
        let entry: [String: Any] = [
            "type": "http",
            "url": serverURL(port: port),
            "headers": ["Authorization": "Bearer \(token)"]
        ]
        try mergeJSON(at: file, serverKey: "ibis", entry: entry, container: "mcpServers")
        return Result(path: file, message: "Wrote Ibis MCP server to \(file.lastPathComponent).")
    }

    // MARK: Antigravity — .agents/mcp_config.json (workspace)

    private static func writeAntigravity(root: URL, port: Int, token: String) throws -> Result {
        let dir = root.appending(path: ".agents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "mcp_config.json")
        let entry: [String: Any] = [
            "serverUrl": serverURL(port: port),
            "headers": ["Authorization": "Bearer \(token)"]
        ]
        try mergeJSON(at: file, serverKey: "ibis", entry: entry, container: "mcpServers")
        return Result(path: file, message: "Wrote Ibis MCP server to .agents/mcp_config.json.")
    }

    // MARK: Codex — .codex/config.toml (project)

    private static func writeCodex(root: URL, port: Int, token: String) throws -> Result {
        let dir = root.appending(path: ".codex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "config.toml")

        // Codex reads the bearer token from an environment variable, not inline.
        let block = """
        [mcp_servers.ibis]
        url = "\(serverURL(port: port))"
        bearer_token_env_var = "IBIS_MCP_TOKEN"
        """

        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let merged = replacingTOMLTable(named: "mcp_servers.ibis", in: existing, with: block)
        try merged.write(to: file, atomically: true, encoding: .utf8)

        return Result(
            path: file,
            message: "Wrote Ibis MCP server to .codex/config.toml. Set IBIS_MCP_TOKEN=\(token) in your environment, and ensure this project is trusted in Codex."
        )
    }

    // MARK: - JSON merge

    private static func mergeJSON(at file: URL, serverKey: String, entry: [String: Any], container: String) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var servers = root[container] as? [String: Any] ?? [:]
        servers[serverKey] = entry
        root[container] = servers

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }

    // MARK: - TOML table merge

    /// Replaces an existing `[name]` table (up to the next table header or EOF)
    /// with `block`, or appends it if absent. Good enough for our single table.
    private static func replacingTOMLTable(named name: String, in contents: String, with block: String) -> String {
        let header = "[\(name)]"
        guard contents.contains(header) else {
            let separator = contents.isEmpty || contents.hasSuffix("\n\n") ? "" : (contents.hasSuffix("\n") ? "\n" : "\n\n")
            return contents + separator + block + "\n"
        }
        var output: [String] = []
        var skipping = false
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == header {
                skipping = true
                output.append(contentsOf: block.components(separatedBy: "\n"))
                continue
            }
            if skipping {
                // Stop skipping at the next table header.
                if trimmed.hasPrefix("[") { skipping = false } else { continue }
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }
}
