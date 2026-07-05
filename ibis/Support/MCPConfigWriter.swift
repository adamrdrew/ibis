import Foundation

/// Writes (or merges) the Ibis MCP server entry into the current project's
/// config file, in the format expected by the user's chosen agent. All agents
/// point at the same Streamable HTTP endpoint (`/mcp`) with a bearer token.
nonisolated enum MCPConfigWriter {
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
        // The file holds a long-lived bearer token — keep it owner-only and out
        // of git so a stray `git add .` can't commit/push it.
        restrictPermissions(file)
        ensureGitignored(".mcp.json", root: root)
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
        // Holds a long-lived bearer token — keep it owner-only and out of git so a
        // stray `git add .` can't commit/push it (same as .mcp.json).
        restrictPermissions(file)
        ensureGitignored(".agents/mcp_config.json", root: root)
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

        // Same rule as mergeJSON: an existing-but-unreadable file aborts rather
        // than being replaced with only our table.
        var existing = ""
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            existing = try String(contentsOf: file, encoding: .utf8)
        }
        let merged = replacingTOMLTable(named: "mcp_servers.ibis", in: existing, with: block)
        try merged.write(to: file, atomically: true, encoding: .utf8)

        return Result(
            path: file,
            message: "Wrote Ibis MCP server to .codex/config.toml. Set IBIS_MCP_TOKEN=\(token) in your environment, and ensure this project is trusted in Codex."
        )
    }

    // MARK: - JSON merge

    struct MergeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func mergeJSON(at file: URL, serverKey: String, entry: [String: Any], container: String) throws {
        var root: [String: Any] = [:]
        // An existing file that can't be read or parsed must abort the merge —
        // falling back to an empty root would atomically replace the user's
        // whole config (every other MCP server they have) with just our entry.
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            let data = try Data(contentsOf: file)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MergeError(message: "\(file.lastPathComponent) exists but isn’t a valid JSON object. Fix or remove it, then try again.")
            }
            root = parsed
        }
        var servers = root[container] as? [String: Any] ?? [:]
        servers[serverKey] = entry
        root[container] = servers

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }

    // MARK: - Hardening

    /// Re-asserts the token-file hardening (0600 + gitignore) on configs written
    /// by builds that predate it — `write` only hardens on the *next* write, so
    /// an existing config can sit world-readable and un-gitignored indefinitely.
    /// Only files that actually carry an Ibis bearer token are touched: a
    /// hand-written `.mcp.json` with no secret may be deliberately committed,
    /// and gitignoring it would silently break that.
    static func hardenExistingConfigs(projectRoot root: URL) {
        for relative in [".mcp.json", ".agents/mcp_config.json"] {
            let file = root.appending(path: relative)
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
                  containsIbisToken(file) else { continue }
            restrictPermissions(file)
            ensureGitignored(relative, root: root)
        }
    }

    /// Whether a JSON config carries an Ibis entry with an inline bearer token.
    private static func containsIbisToken(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let ibis = servers["ibis"] as? [String: Any],
              let headers = ibis["headers"] as? [String: String]
        else { return false }
        return headers["Authorization"]?.hasPrefix("Bearer ") == true
    }

    /// Restricts a written config file to owner read/write (0600) since it holds
    /// a bearer token.
    private static func restrictPermissions(_ file: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path(percentEncoded: false)
        )
    }

    /// Appends `entry` to the project's `.gitignore` (creating it if needed) so a
    /// token-bearing config file never gets committed. Idempotent, additive only.
    private static func ensureGitignored(_ entry: String, root: URL) {
        let gitignore = root.appending(path: ".gitignore")
        var contents = ""
        if FileManager.default.fileExists(atPath: gitignore.path(percentEncoded: false)) {
            // Unreadable .gitignore: skip (best-effort) rather than overwrite it
            // with just our entry.
            guard let existing = try? String(contentsOf: gitignore, encoding: .utf8) else { return }
            contents = existing
        }
        let alreadyListed = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == entry }
        guard !alreadyListed else { return }
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += entry + "\n"
        try? contents.write(to: gitignore, atomically: true, encoding: .utf8)
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
