import Foundation

#if canImport(SwiftMCP)
import SwiftMCP

/// The Ibis MCP server: a thin set of tools that forward onto `MCPBridge` (the
/// `@MainActor` editor facade). Stateless — all shared state lives in the bridge.
@MCPServer(name: "ibis", version: "1.0")
final class IbisMCPServer {
    /// Open a file in a tab in the active Ibis window. The path may be absolute
    /// or relative to the workspace root; pass `line` to scroll to a 1-based line.
    @MCPTool(name: "open_file")
    func openFile(path: String, line: Int? = nil) async throws -> String {
        try await MCPBridge.shared.openFile(path: path, line: line)
    }

    /// The path of the file currently focused in the active Ibis window.
    @MCPTool(name: "get_active_file", readOnlyHint: true)
    func getActiveFile() async throws -> String {
        try await MCPBridge.shared.activeFilePath()
    }

    /// The paths of all files open in tabs in the active Ibis window.
    @MCPTool(name: "get_open_tabs", readOnlyHint: true)
    func getOpenTabs() async throws -> [String] {
        try await MCPBridge.shared.openTabPaths()
    }

    /// The text the human currently has selected in the editor (empty if none).
    @MCPTool(name: "get_selection", readOnlyHint: true)
    func getSelection() async -> String {
        await MCPBridge.shared.currentSelection() ?? ""
    }

    /// The root folder path of the active Ibis workspace.
    @MCPTool(name: "get_workspace_root", readOnlyHint: true)
    func getWorkspaceRoot() async throws -> String {
        try await MCPBridge.shared.workspaceRootPath()
    }

    /// Show a brief, non-blocking banner to the human in the active window.
    @MCPTool(name: "notify")
    func notify(message: String) async -> String {
        await MCPBridge.shared.notify(message)
        return "Shown."
    }

    /// Ask the human a question and wait for their answer. Provide `options` to
    /// present them as buttons; otherwise a single acknowledgement is shown.
    @MCPTool(name: "ask_human")
    func askHuman(question: String, options: [String] = []) async -> String {
        await MCPBridge.shared.askHuman(question: question, options: options.isEmpty ? nil : options)
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

    func start(preferredPort: Int, token: String) {
        guard !isRunning, transport == nil else { return }
        let server = IbisMCPServer()
        let transport = HTTPSSETransport(server: server, host: "127.0.0.1", port: preferredPort)
        transport.authorizationHandler = { provided in
            guard !token.isEmpty else { return .authorized }
            return provided == token ? .authorized : .unauthorized("Invalid token")
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
            MCPServerController.shared.start(preferredPort: settings.mcpPort, token: settings.mcpToken)
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
            MCPServerController.shared.start(preferredPort: settings.mcpPort, token: settings.mcpToken)
        }
        #endif
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
