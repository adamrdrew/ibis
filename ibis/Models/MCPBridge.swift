import AppKit
import Observation

/// Errors surfaced to MCP tool callers as human-readable messages.
enum MCPBridgeError: LocalizedError {
    case noWindow
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .noWindow: "No Ibis window is open."
        case .notFound(let path): "There's no file at \(path)."
        }
    }
}

/// The bridge between the (optional) MCP server and the live editor. Everything
/// here is `@MainActor` and free of any MCP dependency, so the app compiles and
/// behaves identically whether or not the SwiftMCP package is present — the MCP
/// server layer is just a thin forwarder onto these methods.
///
/// It tracks the open workspaces (to resolve "the active window" for a tool) and
/// the most-recently focused editor (for selection reads), and hosts a transient
/// banner that windows display for `notify`.
@MainActor
@Observable
final class MCPBridge {
    static let shared = MCPBridge()
    private init() {}

    private var workspaces: [WeakWorkspace] = []

    /// The editor that most recently became first responder, for `get_selection`.
    @ObservationIgnored weak var activeTextView: NSTextView?

    /// A transient message posted by `notify`, shown by the frontmost window.
    var banner: String?

    // MARK: Registry

    func register(_ workspace: Workspace) {
        prune()
        if !workspaces.contains(where: { $0.value === workspace }) {
            workspaces.append(WeakWorkspace(workspace))
        }
    }

    func unregister(_ workspace: Workspace) {
        workspaces.removeAll { $0.value == nil || $0.value === workspace }
    }

    private func prune() {
        workspaces.removeAll { $0.value == nil }
    }

    /// The workspace whose window is frontmost, falling back to any open one.
    var activeWorkspace: Workspace? {
        let live = workspaces.compactMap(\.value)
        if let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let match = live.first(where: { $0.window === key }) {
            return match
        }
        return live.first
    }

    // MARK: Tools

    /// Opens a file in a tab in the active window, optionally scrolling to a
    /// 1-based line. `path` may be absolute or relative to the workspace root.
    func openFile(path: String, line: Int?) async throws -> String {
        guard let workspace = activeWorkspace else { throw MCPBridgeError.noWindow }
        let url = resolve(path, in: workspace)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPBridgeError.notFound(url.path)
        }
        let document = workspace.document(for: url)
        await document.loadIfNeeded()
        workspace.layout.activePane?.open(document)
        if let line { workspace.goToLine(line) }
        return "Opened \(url.lastPathComponent) in Ibis."
    }

    func activeFilePath() throws -> String {
        guard let workspace = activeWorkspace else { throw MCPBridgeError.noWindow }
        return workspace.activeDocument?.url?.path ?? "(no file open)"
    }

    func openTabPaths() throws -> [String] {
        guard let workspace = activeWorkspace else { throw MCPBridgeError.noWindow }
        var seen = Set<String>()
        var result: [String] = []
        for pane in workspace.layout.panes {
            for document in pane.tabDocuments {
                if let path = document.url?.path, seen.insert(path).inserted {
                    result.append(path)
                }
            }
        }
        return result
    }

    func workspaceRootPath() throws -> String {
        guard let workspace = activeWorkspace else { throw MCPBridgeError.noWindow }
        return workspace.rootURL.path
    }

    /// The human's current editor selection, or nil if nothing is selected.
    func currentSelection() -> String? {
        guard let textView = activeTextView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    func notify(_ message: String) {
        banner = message
    }

    /// Presents a blocking prompt as a sheet on the active window and returns the
    /// button the human chose. `options` become the buttons (default "OK").
    func askHuman(question: String, options: [String]?) async -> String {
        let buttons = (options?.isEmpty == false) ? options! : ["OK"]
        guard let window = activeWorkspace?.window ?? NSApp.keyWindow else {
            return buttons[0]
        }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "The agent is asking:"
            alert.informativeText = question
            for button in buttons { alert.addButton(withTitle: button) }
            alert.beginSheetModal(for: window) { response in
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                let choice = buttons.indices.contains(index) ? buttons[index] : buttons[0]
                continuation.resume(returning: choice)
            }
        }
    }

    // MARK: Helpers

    private func resolve(_ path: String, in workspace: Workspace) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(filePath: expanded).standardizedFileURL
        }
        return workspace.rootURL.appending(path: expanded).standardizedFileURL
    }
}

private struct WeakWorkspace {
    weak var value: Workspace?
    init(_ value: Workspace) { self.value = value }
}
