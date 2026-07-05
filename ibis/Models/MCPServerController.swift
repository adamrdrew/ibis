import Foundation

#if canImport(SwiftMCP)
import SwiftMCP

/// The Ibis MCP server: a thin set of tools that forward onto `MCPBridge` (the
/// `@MainActor` editor facade). Stateless — all shared state lives in the bridge.
@MCPServer(name: "ibis", version: "1.0")
final class IbisMCPServer {
    /// The bearer token of the current connection, which identifies the project
    /// window this agent is bound to. Every tool routes by this.
    private func projectToken() async -> String? {
        guard let session = Session.current else { return nil }
        return await session.accessToken
    }

    /// Open a file in a tab in this agent's Ibis window. The path may be absolute
    /// or relative to the workspace root; pass `line` to scroll to a 1-based line.
    @MCPTool(name: "open_file")
    func openFile(path: String, line: Int? = nil) async throws -> String {
        try await MCPBridge.shared.openFile(token: await projectToken(), path: path, line: line)
    }

    /// Propose an edit to a file and wait for the human to review it. Send the
    /// full intended new content; Ibis shows the human a diff against the current
    /// file and, only if they approve, applies and saves it. Returns whether the
    /// human applied or declined.
    @MCPTool(name: "propose_edit")
    func proposeEdit(path: String, newContent: String) async throws -> String {
        try await MCPBridge.shared.proposeEdit(token: await projectToken(), path: path, newContent: newContent)
    }

    /// Open content in a new, unsaved tab (no file is created). Use this to show
    /// the human a report, summary, or draft. `format` is "markdown", "html", or
    /// "text"; Markdown and HTML render, "text" shows editable source. If omitted,
    /// the format is inferred. The human can edit and Save As to keep it.
    @MCPTool(name: "open_content")
    func openContent(title: String, content: String, format: String? = nil) async throws -> String {
        try await MCPBridge.shared.openContent(token: await projectToken(), title: title, content: content, format: format)
    }

    /// Propose one or more find-and-replace edits to a file and wait for the
    /// human to review the resulting diff. Prefer this over open_file+propose_edit
    /// for small or surgical changes — it keeps corrections cheap and still routes
    /// them through the same approval gate. Each edit's `oldString` must match the
    /// file exactly and uniquely (include context) unless `replaceAll` is set.
    @MCPTool(name: "propose_patch")
    func proposePatch(path: String, edits: [ProposedEdit]) async throws -> String {
        try await MCPBridge.shared.proposePatch(token: await projectToken(), path: path, edits: edits)
    }

    /// Reveal a file in this agent's file browser (expand to it and select it).
    /// The path may be absolute or relative to the workspace root.
    @MCPTool(name: "reveal_in_tree")
    func revealInTree(path: String) async throws -> String {
        try await MCPBridge.shared.revealInTree(token: await projectToken(), path: path)
    }

    /// The path of the file currently focused in this agent's Ibis window.
    @MCPTool(name: "get_active_file", readOnlyHint: true)
    func getActiveFile() async throws -> String {
        try await MCPBridge.shared.activeFilePath(token: await projectToken())
    }

    /// The paths of all files open in tabs in this agent's Ibis window.
    @MCPTool(name: "get_open_tabs", readOnlyHint: true)
    func getOpenTabs() async throws -> [String] {
        try await MCPBridge.shared.openTabPaths(token: await projectToken())
    }

    /// The text the human currently has selected in this window (empty if none).
    @MCPTool(name: "get_selection", readOnlyHint: true)
    func getSelection() async throws -> String {
        try await MCPBridge.shared.currentSelection(token: await projectToken())
    }

    /// The root folder path of this agent's Ibis workspace.
    @MCPTool(name: "get_workspace_root", readOnlyHint: true)
    func getWorkspaceRoot() async throws -> String {
        try await MCPBridge.shared.workspaceRootPath(token: await projectToken())
    }

    /// Show a brief, non-blocking banner to the human in this window.
    @MCPTool(name: "notify")
    func notify(message: String) async throws -> String {
        try await MCPBridge.shared.notify(token: await projectToken(), message: message)
        return "Shown."
    }

    /// Ask the human a question with a sheet *in their editor window* and wait
    /// for their answer. Use this (rather than a chat-side question) when the
    /// question is about what they're looking at in Ibis — it interrupts them
    /// where their attention already is. Provide `options` to present buttons.
    @MCPTool(name: "ask_human")
    func askHuman(question: String, options: [String] = []) async throws -> String {
        try await MCPBridge.shared.askHuman(token: await projectToken(), question: question, options: options.isEmpty ? nil : options)
    }
}

/// Owns the running MCP server + HTTP transport, bound to 127.0.0.1.
@MainActor
@Observable
final class MCPServerController {
    static let shared = MCPServerController()
    private init() {}

    private(set) var isRunning = false
    private(set) var activePort = 0
    /// Set when the listener failed to start (e.g. the port is already taken), so
    /// the UI can warn instead of silently not listening.
    private(set) var startError: String?

    @ObservationIgnored private var transport: HTTPSSETransport?

    func start(preferredPort: Int) {
        guard !isRunning, transport == nil else { return }
        startError = nil
        let server = IbisMCPServer()
        let transport = HTTPSSETransport(server: server, host: "127.0.0.1", port: preferredPort)
        // Accept any token that belongs to a currently-open project window. The
        // token then routes each request to that project (see IbisMCPServer).
        transport.authorizationHandler = { provided in
            guard let provided, MCPTokenRegistry.shared.contains(provided) else {
                return .unauthorized("Unknown or closed project token")
            }
            return .authorized
        }
        self.transport = transport
        Task {
            do {
                try await transport.start()
                // stop() (or a port-change restart) may have detached this
                // transport while it was still binding. It owns the state now;
                // shut the orphaned listener down instead of adopting it —
                // otherwise the UI says "off" while the port stays taken.
                guard self.transport === transport else {
                    try? await transport.stop()
                    return
                }
                self.activePort = transport.port
                self.isRunning = true
            } catch {
                guard self.transport === transport else { return }
                self.transport = nil
                self.isRunning = false
                self.startError = "Couldn’t start on port \(preferredPort): \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        guard let transport else {
            isRunning = false
            return
        }
        self.transport = nil
        isRunning = false
        activePort = 0
        Task { try? await transport.stop() }
    }
}
#endif

/// Always-compiled facade so the app builds and the Settings UI works whether or
/// not the SwiftMCP package is present.
@MainActor
enum MCPService {
    /// Whether the MCP server feature is compiled in (SwiftMCP package present).
    static var isAvailable: Bool {
        #if canImport(SwiftMCP)
        true
        #else
        false
        #endif
    }

    /// Starts or stops the server to match the current settings. Idempotent.
    static func apply(settings: AppSettings) {
        #if canImport(SwiftMCP)
        if settings.mcpEnabled {
            MCPServerController.shared.start(preferredPort: settings.mcpPort)
        } else {
            MCPServerController.shared.stop()
        }
        #endif
    }

    /// Stops and (if enabled) restarts the server to pick up a changed port or
    /// token, leaving time for the old listener to release the port.
    static func restart(settings: AppSettings) {
        #if canImport(SwiftMCP)
        MCPServerController.shared.stop()
        guard settings.mcpEnabled else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            MCPServerController.shared.start(preferredPort: settings.mcpPort)
        }
        #endif
    }

    /// Orientation injected into the agent's context at launch, so it knows it
    /// is running in Ibis and how to use the Ibis tools. No apostrophes/quotes so
    /// it embeds safely in a single-quoted shell argument.
    static let agentOrientation = """
    You are running inside Ibis, a collaborative workspace where a human and an agent work together in a single project window. The human directs and reviews the work and may not read code directly, so prefer showing results in Ibis over pasting large output into the terminal.

    You have Ibis tools (via MCP) scoped to THIS project window:
    - open_file(path, line): open a file in a tab for the human to see, optionally at a line.
    - reveal_in_tree(path): select a file in the file browser.
    - open_content(title, content, format): open rich output in a new unsaved tab. Use markdown or html when the answer is best shown as a rendered report, summary, table, or document rather than plain terminal text.
    - propose_edit and propose_patch: make code changes that the human reviews as a diff and approves before they are applied and saved.
    - ask_human(question, options): ask the human a question in their editor when it concerns what they are looking at.
    - get_active_file, get_selection, get_open_tabs, get_workspace_root: see what the human is currently focused on.

    When the human asks to open or see a file, use open_file. When they ask for information best represented richly, build it as markdown or html and open it with open_content.
    """

    /// The shell command to launch the configured agent, augmented with the Ibis
    /// orientation when we know how to inject it (Claude) and MCP is on. Returns
    /// nil if no agent is configured.
    ///
    /// For Claude, `sessionID` pins the conversation to a stable UUID so window
    /// restoration can bring it back: `--session-id` on a fresh launch
    /// (`resume == false`), `--resume` on restore. The system prompt is applied
    /// in both cases — `--append-system-prompt` is per-invocation (Claude does
    /// not store it in the session), so a resumed conversation needs it
    /// re-injected just like a fresh one.
    static func launchCommand(settings: AppSettings, sessionID: String? = nil, resume: Bool = false) -> String? {
        guard let base = settings.agentCommandLine else { return nil }
        guard settings.agentKind == .claude else { return base }
        // The id is interpolated into a `shell -l -c` string, so accept nothing
        // but a well-formed UUID: on the restore path it comes from persisted
        // UserDefaults, and a corrupted or tampered value must not reach the
        // shell. A rejected id degrades to an unpinned fresh launch.
        let sessionID = sessionID.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }

        var command = base
        if let sessionID {
            command += (resume ? " --resume " : " --session-id ") + sessionID
        }
        if settings.mcpEnabled, settings.agentInjectSystemPrompt {
            let prompt = agentOrientation.replacingOccurrences(of: "'", with: "")
            command += " --append-system-prompt '" + prompt + "'"
        }
        return command
    }

    /// The command to relaunch an agent tab that owns `sessionID`: `--resume`
    /// when the conversation exists on disk, else re-pinned to the same
    /// `--session-id` (resuming a transcript-less session fails with "No
    /// conversation found", while re-pinning an existing one fails with
    /// "already in use" — this picks whichever works). The single home of that
    /// rule, shared by window restore and the exited-overlay Restart.
    static func agentRelaunchCommand(
        settings: AppSettings, sessionID: String, workingDirectory: URL
    ) -> (command: String, resume: Bool)? {
        let resume = claudeSessionFileExists(sessionID: sessionID, workingDirectory: workingDirectory)
        guard let command = launchCommand(settings: settings, sessionID: sessionID, resume: resume) else { return nil }
        return (command, resume)
    }

    /// Whether Claude Code has a transcript on disk for `sessionID`
    /// (`~/.claude/projects/<dir>/<id>.jsonl`). Claude creates the file lazily
    /// on the first message, so a launched-but-never-used session has none:
    /// `--resume` on it fails ("No conversation found"), while relaunching
    /// pinned to the same `--session-id` works. This check picks between those,
    /// and stops recovery from ever replacing a session ID whose conversation
    /// still exists.
    ///
    /// Checks the slug-named directory first, then falls back to scanning every
    /// project directory: Claude's real directory name can diverge from our
    /// slug (it truncates + hashes long paths, and its naming rule is an
    /// undocumented internal that can change), and session UUIDs are unique, so
    /// a transcript found anywhere means the conversation exists.
    static func claudeSessionFileExists(sessionID: String, workingDirectory: URL) -> Bool {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: ".claude", "projects")
        let transcript = sessionID + ".jsonl"
        let slugged = projects
            .appending(components: claudeProjectSlug(for: workingDirectory), transcript)
        if FileManager.default.fileExists(atPath: slugged.path(percentEncoded: false)) { return true }
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        ) else { return false }
        return dirs.contains {
            FileManager.default.fileExists(atPath: $0.appending(component: transcript).path(percentEncoded: false))
        }
    }

    /// Claude Code's per-project directory name: the cwd path with every
    /// character outside `[a-zA-Z0-9]` replaced by "-". Claude applies that
    /// replacement per UTF-16 code unit (a JavaScript regex without the `u`
    /// flag), so a non-BMP character like an emoji becomes *two* dashes —
    /// mapping `utf16` here, not scalars, mirrors that. Claude also truncates
    /// and hash-suffixes very long slugs, which this deliberately does not
    /// replicate: `claudeSessionFileExists` falls back to a directory scan.
    static func claudeProjectSlug(for workingDirectory: URL) -> String {
        let path = workingDirectory.path(percentEncoded: false).strippingTrailingSlashes
        let mapped = path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: Character(UnicodeScalar(unit)!)
            default: "-"
            }
        }
        return String(mapped)
    }

    /// Before launching an agent into a project, write that project's MCP config
    /// (pointing at the running server with the project's token) so the hosted
    /// agent is automatically bound to its own window. No-op if MCP is off.
    static func bindAgent(to workspace: Workspace, settings: AppSettings) {
        guard settings.mcpEnabled, let port = runningPort else { return }
        let token = MCPBridge.shared.token(for: workspace)
        do {
            _ = try MCPConfigWriter.write(
                agent: settings.agentKind,
                // Use the project directory, not rootURL: for a single-file workspace
                // rootURL is the *file*, so writing "<file>/.mcp.json" would fail and
                // leave the agent unbound. projectRoot is where the agent's cwd is.
                projectRoot: workspace.projectRoot,
                port: port,
                token: token
            )
        } catch {
            // The merge deliberately aborts on an unparseable existing config;
            // swallowing that here would launch the agent with no Ibis tools
            // and no explanation anywhere.
            workspace.presentError("The agent is starting without Ibis tools — its MCP config couldn’t be written. \(error.localizedDescription)")
        }
    }

    /// The bound port if the server is running, else nil.
    static var runningPort: Int? {
        #if canImport(SwiftMCP)
        MCPServerController.shared.isRunning ? MCPServerController.shared.activePort : nil
        #else
        nil
        #endif
    }

    /// A start-up error (e.g. the port was already taken), if any.
    static var startError: String? {
        #if canImport(SwiftMCP)
        MCPServerController.shared.startError
        #else
        nil
        #endif
    }
}
