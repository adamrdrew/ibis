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

    /// Whether a project already carries an agent MCP config, and whether the
    /// Ibis entry is in it — so Ibis can proactively offer to add itself to a
    /// project that already uses MCP but doesn't yet point at Ibis.
    enum ProjectConfigState: Equatable {
        /// No agent MCP config file (for the chosen agent) exists in the project.
        case none
        /// A config exists and already references the Ibis server.
        case ibisPresent
        /// A config exists but doesn't reference Ibis yet.
        case missingIbis
    }

    /// Inspects the project for the config file the chosen agent reads, without
    /// modifying anything. An unreadable/unparseable JSON config reports `.none`:
    /// it can't be safely merged (the merge in `write` aborts on it anyway), so
    /// there's nothing to cleanly offer.
    static func projectState(agent: AgentKind, projectRoot: URL) -> ProjectConfigState {
        switch agent {
        case .claude, .custom:
            return jsonState(file: projectRoot.appending(path: ".mcp.json"))
        case .antigravity:
            return jsonState(file: projectRoot.appending(path: ".agents/mcp_config.json"))
        case .codex:
            return codexState(file: projectRoot.appending(path: ".codex/config.toml"))
        }
    }

    private static func jsonState(file: URL) -> ProjectConfigState {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return .none }
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .none }
        let servers = root["mcpServers"] as? [String: Any]
        return servers?["ibis"] != nil ? .ibisPresent : .missingIbis
    }

    private static func codexState(file: URL) -> ProjectConfigState {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return .none }
        // Line-anchored, not substring: a commented-out `# [mcp_servers.ibis]`
        // must not report the entry as present (it would permanently suppress
        // the adoption offer while writes silently no-op).
        return tomlHasTable(named: "mcp_servers.ibis", in: contents) ? .ibisPresent : .missingIbis
    }

    /// Whether the project's `.mcp.json` carries a legacy *hardcoded* Ibis
    /// entry — an inline bearer token, or a URL with a literal port instead of
    /// `${IBIS_MCP_PORT}`. Such an entry leaks the writer's token if committed,
    /// and resolves only on the machine (and app launch) that wrote it.
    static func claudeConfigNeedsPortabilityUpgrade(projectRoot root: URL) -> Bool {
        let file = root.appending(path: ".mcp.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let ibis = servers["ibis"] as? [String: Any]
        else { return false }
        let authorization = (ibis["headers"] as? [String: String])?["Authorization"] ?? ""
        if authorization.hasPrefix("Bearer "), !authorization.contains("${") { return true }
        if let url = ibis["url"] as? String, url.contains("127.0.0.1"), !url.contains("${") { return true }
        return false
    }

    /// Rewrites a legacy hardcoded Ibis entry to the portable env-var form and
    /// undoes the old secret-file hardening that no longer applies: the file is
    /// restored to 0644 and Ibis's own `.gitignore` line is removed — with no
    /// secret inside, `.mcp.json` is meant to be committed and shared, and a
    /// leftover ignore line would silently keep it out of the team's repo.
    static func upgradeClaudeConfigPortability(projectRoot root: URL, port: Int, token: String) throws -> Result {
        let result = try writeClaude(root: root, port: port, token: token)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: result.path.path(percentEncoded: false)
        )
        removeGitignoreEntry(".mcp.json", root: root)
        return result
    }

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
        // Both the secret and the machine-specific port are env-var references
        // (Claude Code expands `${VAR}` in .mcp.json), so the file contains
        // nothing machine- or launch-specific: it can be committed and shared,
        // and each machine's Ibis supplies its own live values through the
        // integrated-terminal environment. Inlining either broke that —
        // the token was one `git add . && git push` from public (gitignore
        // can't protect an already-tracked file), and the port (ephemeral by
        // default) went stale on any other machine, or on this one after a
        // relaunch. External shells need both exported manually (see the
        // message); pinning a fixed port in Settings makes that stable.
        let entry: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:${IBIS_MCP_PORT}/mcp",
            "headers": ["Authorization": "Bearer ${IBIS_MCP_TOKEN}"]
        ]
        try mergeJSON(at: file, serverKey: "ibis", entry: entry, container: "mcpServers")
        return Result(
            path: file,
            message: "Wrote Ibis MCP server to \(file.lastPathComponent). Ibis sets IBIS_MCP_TOKEN and IBIS_MCP_PORT automatically in its integrated terminal; to use Claude from another terminal, set IBIS_MCP_TOKEN=\(token) and IBIS_MCP_PORT=\(port) there."
        )
    }

    // MARK: Antigravity — .agents/mcp_config.json (workspace)

    private static func writeAntigravity(root: URL, port: Int, token: String) throws -> Result {
        // This config carries the raw token (Antigravity has no env-var
        // indirection), and appending to .gitignore does nothing for a file git
        // already tracks — refuse rather than stage a secret for the next
        // `git add . && git push`.
        if isGitTracked(".agents/mcp_config.json", root: root) {
            throw MergeError(message: ".agents/mcp_config.json is tracked in git, and the Ibis entry contains a secret token. Untrack it first (git rm --cached .agents/mcp_config.json), then try again.")
        }
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
            message: "Wrote Ibis MCP server to .codex/config.toml. Ibis sets IBIS_MCP_TOKEN automatically in its integrated terminal; to use Codex from another terminal, set IBIS_MCP_TOKEN=\(token) there. Ensure this project is trusted in Codex."
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
    /// A `${IBIS_MCP_TOKEN}` env-var reference is not a secret — hardening that
    /// file would wrongly chmod and gitignore a config that's safe to commit.
    private static func containsIbisToken(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let ibis = servers["ibis"] as? [String: Any],
              let headers = ibis["headers"] as? [String: String],
              let authorization = headers["Authorization"]
        else { return false }
        return authorization.hasPrefix("Bearer ") && !authorization.contains("${")
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

    /// Removes Ibis's own `entry` line from `.gitignore` — the inverse of
    /// `ensureGitignored`, for configs upgraded to the secret-free form. Only
    /// the exact line is dropped; everything else (including user comments and
    /// patterns) is preserved byte-for-byte.
    private static func removeGitignoreEntry(_ entry: String, root: URL) {
        let gitignore = root.appending(path: ".gitignore")
        guard let contents = try? String(contentsOf: gitignore, encoding: .utf8) else { return }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { $0.trimmingCharacters(in: .whitespaces) != entry }
        guard kept.count != lines.count else { return }
        try? kept.joined(separator: "\n").write(to: gitignore, atomically: true, encoding: .utf8)
    }

    /// Whether `relative` is tracked by git in `root` (best effort: false when
    /// git is missing or the folder isn't a repository).
    private static func isGitTracked(_ relative: String, root: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path(percentEncoded: false), "ls-files", "--error-unmatch", relative]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - TOML table merge

    /// Whether `contents` has a real (non-commented) `[name]` table header.
    private static func tomlHasTable(named name: String, in contents: String) -> Bool {
        let header = "[\(name)]"
        return contents
            .components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == header }
    }

    /// Replaces an existing `[name]` table (up to the next table header or EOF)
    /// with `block`, or appends it if absent. Good enough for our single table.
    /// Presence uses the same line-anchored test as the replacement scan — a
    /// substring check would see a commented-out header, take the "replace"
    /// branch, match no line, and write the file back unchanged while reporting
    /// success.
    private static func replacingTOMLTable(named name: String, in contents: String, with block: String) -> String {
        let header = "[\(name)]"
        guard tomlHasTable(named: name, in: contents) else {
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
