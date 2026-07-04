import SwiftUI
import Observation

/// Where the integrated terminal dock sits relative to the editor.
enum TerminalPlacement: String, CaseIterable {
    case bottom
    case trailing
}

/// The coding agent the user runs, which determines the MCP config file format
/// Ibis writes for it.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude
    case codex
    case antigravity
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .custom: "Custom"
        }
    }
}

/// User-configurable editor and appearance settings, shared across all windows
/// through the environment and persisted to `UserDefaults`.
@Observable
@MainActor
final class AppSettings {
    var fontName: String { didSet { defaults.set(fontName, forKey: Key.fontName) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: Key.tabWidth) } }
    var usesSoftTabs: Bool { didSet { defaults.set(usesSoftTabs, forKey: Key.usesSoftTabs) } }
    var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: Key.showLineNumbers) } }
    var wordWrap: Bool { didSet { defaults.set(wordWrap, forKey: Key.wordWrap) } }

    /// Syntax highlighting themes, used according to the system appearance.
    var lightTheme: String { didSet { defaults.set(lightTheme, forKey: Key.lightTheme) } }
    var darkTheme: String { didSet { defaults.set(darkTheme, forKey: Key.darkTheme) } }

    // MARK: Integrated terminal

    /// Font for the integrated terminal (separate from the editor font).
    var terminalFontName: String { didSet { defaults.set(terminalFontName, forKey: Key.terminalFontName) } }
    var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: Key.terminalFontSize) } }
    /// Optional shell override; empty means use the user's login shell.
    var terminalShellPath: String { didSet { defaults.set(terminalShellPath, forKey: Key.terminalShellPath) } }
    /// Remembered size of the terminal dock (height when at the bottom, width
    /// when trailing).
    var terminalDockHeight: Double { didSet { defaults.set(terminalDockHeight, forKey: Key.terminalDockHeight) } }
    var terminalDockWidth: Double { didSet { defaults.set(terminalDockWidth, forKey: Key.terminalDockWidth) } }
    /// Whether the terminal dock sits at the bottom or along the trailing edge.
    var terminalPlacement: TerminalPlacement {
        didSet { defaults.set(terminalPlacement.rawValue, forKey: Key.terminalPlacement) }
    }

    // MARK: Agent

    /// A configurable command-line agent (e.g. `claude`, `codex`) launched in a
    /// terminal by the "Open in Agent" action.
    var agentName: String { didSet { defaults.set(agentName, forKey: Key.agentName) } }
    var agentCommand: String { didSet { defaults.set(agentCommand, forKey: Key.agentCommand) } }
    var agentArgs: String { didSet { defaults.set(agentArgs, forKey: Key.agentArgs) } }
    /// Which agent the user runs, so Ibis can write that agent's MCP config format.
    var agentKind: AgentKind { didSet { defaults.set(agentKind.rawValue, forKey: Key.agentKind) } }

    // MARK: MCP server

    /// Whether Ibis's embedded MCP server is enabled (lets agents drive/read the
    /// editor). Off by default; binds to 127.0.0.1 only.
    var mcpEnabled: Bool { didSet { defaults.set(mcpEnabled, forKey: Key.mcpEnabled) } }
    /// Preferred listen port (0 = pick an ephemeral port).
    var mcpPort: Int { didSet { defaults.set(mcpPort, forKey: Key.mcpPort) } }
    /// Shared bearer token required by the server and written into agent configs.
    var mcpToken: String { didSet { defaults.set(mcpToken, forKey: Key.mcpToken) } }

    /// The shell-ready command line for the configured agent, or nil if unset.
    var agentCommandLine: String? {
        let command = agentCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        let args = agentArgs.trimmingCharacters(in: .whitespaces)
        return args.isEmpty ? command : "\(command) \(args)"
    }

    // Not yet surfaced in the UI; kept for the editor configuration.
    var lineSpacing: Double = 2
    var showInvisibles: Bool = false

    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        // `didSet` doesn't fire for these initial assignments, so nothing is
        // written back during load.
        fontName = defaults.string(forKey: Key.fontName) ?? "SF Mono"
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? 13
        tabWidth = defaults.object(forKey: Key.tabWidth) as? Int ?? 4
        usesSoftTabs = defaults.object(forKey: Key.usesSoftTabs) as? Bool ?? true
        showLineNumbers = defaults.object(forKey: Key.showLineNumbers) as? Bool ?? true
        wordWrap = defaults.object(forKey: Key.wordWrap) as? Bool ?? false
        lightTheme = defaults.string(forKey: Key.lightTheme) ?? "atom-one-light"
        darkTheme = defaults.string(forKey: Key.darkTheme) ?? "atom-one-dark"
        terminalFontName = defaults.string(forKey: Key.terminalFontName) ?? "SF Mono"
        terminalFontSize = defaults.object(forKey: Key.terminalFontSize) as? Double ?? 13
        terminalShellPath = defaults.string(forKey: Key.terminalShellPath) ?? ""
        terminalDockHeight = defaults.object(forKey: Key.terminalDockHeight) as? Double ?? 240
        terminalDockWidth = defaults.object(forKey: Key.terminalDockWidth) as? Double ?? 480
        terminalPlacement = defaults.string(forKey: Key.terminalPlacement)
            .flatMap(TerminalPlacement.init) ?? .bottom
        agentName = defaults.string(forKey: Key.agentName) ?? "Claude"
        agentCommand = defaults.string(forKey: Key.agentCommand) ?? "claude"
        agentArgs = defaults.string(forKey: Key.agentArgs) ?? ""
        agentKind = defaults.string(forKey: Key.agentKind).flatMap(AgentKind.init) ?? .claude
        mcpEnabled = defaults.bool(forKey: Key.mcpEnabled)
        // Default to an ephemeral port (0 = OS-assigned): a fixed, well-known port
        // lets another local process squat it and phish tokens. Configs are
        // (re)written with the actually-bound port at agent-launch time.
        mcpPort = defaults.object(forKey: Key.mcpPort) as? Int ?? 0
        // `didSet` doesn't fire during init, so persist a freshly generated token
        // explicitly — otherwise it changes every launch and never round-trips.
        if let storedToken = defaults.string(forKey: Key.mcpToken) {
            mcpToken = storedToken
        } else {
            let generated = Self.generateToken()
            mcpToken = generated
            defaults.set(generated, forKey: Key.mcpToken)
        }
    }

    /// A URL-safe random token used as the MCP bearer credential.
    static func freshToken() -> String { generateToken() }

    private static func generateToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private enum Key {
        static let fontName = "editor.fontName"
        static let fontSize = "editor.fontSize"
        static let tabWidth = "editor.tabWidth"
        static let usesSoftTabs = "editor.usesSoftTabs"
        static let showLineNumbers = "editor.showLineNumbers"
        static let wordWrap = "editor.wordWrap"
        static let lightTheme = "editor.lightTheme"
        static let darkTheme = "editor.darkTheme"
        static let terminalFontName = "terminal.fontName"
        static let terminalFontSize = "terminal.fontSize"
        static let terminalShellPath = "terminal.shellPath"
        static let terminalDockHeight = "terminal.dockHeight"
        static let terminalDockWidth = "terminal.dockWidth"
        static let terminalPlacement = "terminal.placement"
        static let agentName = "agent.name"
        static let agentCommand = "agent.command"
        static let agentArgs = "agent.args"
        static let agentKind = "agent.kind"
        static let mcpEnabled = "mcp.enabled"
        static let mcpPort = "mcp.port"
        static let mcpToken = "mcp.token"
    }
}
