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

    /// Ask the human a question and wait for their answer. Provide `options` to
    /// present them as buttons; otherwise a single acknowledgement is shown.
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

    @ObservationIgnored private var transport: HTTPSSETransport?

    func start(preferredPort: Int) {
        guard !isRunning, transport == nil else { return }
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
                self.activePort = transport.port
                self.isRunning = true
            } catch {
                self.transport = nil
                self.isRunning = false
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

    /// Before launching an agent into a project, write that project's MCP config
    /// (pointing at the running server with the project's token) so the hosted
    /// agent is automatically bound to its own window. No-op if MCP is off.
    static func bindAgent(to workspace: Workspace, settings: AppSettings) {
        guard settings.mcpEnabled, let port = runningPort else { return }
        let token = MCPBridge.shared.token(for: workspace)
        _ = try? MCPConfigWriter.write(
            agent: settings.agentKind,
            projectRoot: workspace.rootURL,
            port: port,
            token: token
        )
    }

    /// The bound port if the server is running, else nil.
    static var runningPort: Int? {
        #if canImport(SwiftMCP)
        MCPServerController.shared.isRunning ? MCPServerController.shared.activePort : nil
        #else
        nil
        #endif
    }
}
