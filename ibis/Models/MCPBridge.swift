import AppKit
import Observation

/// Errors surfaced to MCP tool callers as human-readable messages.
enum MCPBridgeError: LocalizedError {
    case noWindow

    var errorDescription: String? {
        switch self {
        case .noWindow: "No Ibis window is bound to this agent's project (is it still open?)."
        }
    }
}

/// The bridge between the MCP server and the live editor. Everything here is
/// `@MainActor` and free of any MCP dependency, so the app compiles and behaves
/// identically whether or not the SwiftMCP package is present.
///
/// Each open workspace has a stable per-project token. Tool calls carry the
/// token of the project the agent was launched in (its connection's bearer
/// token), and every tool routes to *that* window — so an agent can only ever
/// reach its own project's window, decided by the connection, never per call.
@MainActor
@Observable
final class MCPBridge {
    static let shared = MCPBridge()
    private init() {}

    /// token → workspace, for routing tool calls.
    private var byToken: [String: WeakWorkspace] = [:]

    /// A transient message posted by `notify`, shown by the frontmost window.
    /// (Banners are per-window in the UI via `bannerToken`.)
    var banner: String?
    /// The token of the workspace whose banner should show.
    @ObservationIgnored var bannerToken: String?

    // MARK: Registry

    /// Registers a workspace and returns its stable project token.
    @discardableResult
    func register(_ workspace: Workspace) -> String {
        prune()
        let token = MCPTokenStore.token(for: workspace.rootURL)
        byToken[token] = WeakWorkspace(workspace, token: token)
        MCPTokenRegistry.shared.insert(token)
        return token
    }

    func unregister(_ workspace: Workspace) {
        for (token, box) in byToken where box.value == nil || box.value === workspace {
            byToken.removeValue(forKey: token)
            MCPTokenRegistry.shared.remove(token)
        }
    }

    private func prune() {
        for (token, box) in byToken where box.value == nil {
            byToken.removeValue(forKey: token)
            MCPTokenRegistry.shared.remove(token)
        }
    }

    /// The project token for a workspace (used by config writing / launch).
    func token(for workspace: Workspace) -> String {
        MCPTokenStore.token(for: workspace.rootURL)
    }

    /// The frontmost workspace, for the Settings UI (not for tool routing).
    var frontmostWorkspace: Workspace? {
        let live = byToken.values.compactMap(\.value)
        if let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let match = live.first(where: { $0.window === key }) {
            return match
        }
        return live.first
    }

    /// Records which editor last had focus, attributing it to its window's
    /// workspace so `get_selection` reads from the correct window.
    func noteFocusedEditor(_ textView: NSTextView, in window: NSWindow) {
        for box in byToken.values {
            if let workspace = box.value, workspace.window === window {
                workspace.focusedEditor = textView
                return
            }
        }
    }

    // MARK: Tool routing

    private func workspace(for token: String?) throws -> Workspace {
        guard let token, let workspace = byToken[token]?.value else {
            throw MCPBridgeError.noWindow
        }
        return workspace
    }

    // MARK: Tools (each scoped to the caller's project by token)

    func openFile(token: String?, path: String, line: Int?) async throws -> String {
        let workspace = try workspace(for: token)
        let url = resolve(path, in: workspace)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPToolFailure("There's no file at \(url.path).")
        }
        let document = workspace.document(for: url)
        await document.loadIfNeeded()
        workspace.layout.activePane?.open(document)
        if let line { workspace.goToLine(line) }
        return "Opened \(url.lastPathComponent) in Ibis."
    }

    /// Shows the human a diff of `newContent` vs the current file and waits for
    /// their decision, applying it (buffer + save) only if approved.
    func proposeEdit(token: String?, path: String, newContent: String) async throws -> String {
        let (workspace, url) = try target(token: token, path: path)
        return try await reviewAndApply(in: workspace, url: url, before: currentContent(of: url, in: workspace), after: newContent)
    }

    /// Applies a set of `old → new` string edits to the current file content and
    /// runs the same diff review. Small, surgical edits stay cheap and still go
    /// through the approval gate. Errors are actionable so a mismatch is
    /// re-proposed through the gate rather than routed around it.
    func proposePatch(token: String?, path: String, edits: [ProposedEdit]) async throws -> String {
        let (workspace, url) = try target(token: token, path: path)
        let before = currentContent(of: url, in: workspace)
        let after = try applyEdits(edits, to: before, fileName: url.lastPathComponent)
        return try await reviewAndApply(in: workspace, url: url, before: before, after: after)
    }

    // MARK: Edit helpers

    private func target(token: String?, path: String) throws -> (Workspace, URL) {
        let workspace = try workspace(for: token)
        return (workspace, resolve(path, in: workspace))
    }

    private func currentContent(of url: URL, in workspace: Workspace) -> String {
        workspace.openedDocument(for: url)?.text
            ?? (try? String(contentsOf: url, encoding: .utf8))
            ?? ""
    }

    private func applyEdits(_ edits: [ProposedEdit], to content: String, fileName: String) throws -> String {
        guard !edits.isEmpty else { throw MCPToolFailure("No edits provided.") }
        var working = content
        for (index, edit) in edits.enumerated() {
            let n = index + 1
            guard !edit.oldString.isEmpty else {
                throw MCPToolFailure("Edit \(n): oldString is empty.")
            }
            if edit.replaceAll == true {
                guard working.contains(edit.oldString) else {
                    throw MCPToolFailure("Edit \(n): the text to replace wasn't found in \(fileName).")
                }
                working = working.replacingOccurrences(of: edit.oldString, with: edit.newString)
            } else {
                let occurrences = working.components(separatedBy: edit.oldString).count - 1
                if occurrences == 0 {
                    throw MCPToolFailure("Edit \(n): the text to replace wasn't found in \(fileName). Re-read the file and match it exactly (including whitespace).")
                }
                if occurrences > 1 {
                    throw MCPToolFailure("Edit \(n): the text to replace appears \(occurrences) times in \(fileName). Add surrounding context to make it unique, or set replaceAll.")
                }
                if let range = working.range(of: edit.oldString) {
                    working.replaceSubrange(range, with: edit.newString)
                }
            }
        }
        return working
    }

    private func reviewAndApply(in workspace: Workspace, url: URL, before: String, after: String) async throws -> String {
        guard let proposal = LineDiff.proposal(fileURL: url, before: before, after: after) else {
            return "No changes to \(url.lastPathComponent) — the result matches the current file."
        }
        guard workspace.pendingDiff == nil else {
            throw MCPToolFailure("A diff review is already open in this window; resolve it first.")
        }
        let approved = await workspace.awaitDiffDecision(proposal)
        if approved {
            await workspace.applyProposedEdit(url: url, content: after)
            return "Applied changes to \(url.lastPathComponent) (+\(proposal.added) −\(proposal.removed))."
        }
        return "The human declined the changes to \(url.lastPathComponent)."
    }

    func revealInTree(token: String?, path: String) throws -> String {
        let workspace = try workspace(for: token)
        let url = resolve(path, in: workspace)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPToolFailure("There's no file at \(url.path).")
        }
        workspace.requestRevealInTree(url)
        return "Revealed \(url.lastPathComponent) in the file browser."
    }

    func activeFilePath(token: String?) throws -> String {
        let workspace = try workspace(for: token)
        return workspace.activeDocument?.url?.path ?? "(no file open)"
    }

    func openTabPaths(token: String?) throws -> [String] {
        let workspace = try workspace(for: token)
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

    func workspaceRootPath(token: String?) throws -> String {
        try workspace(for: token).rootURL.path
    }

    func currentSelection(token: String?) throws -> String {
        let workspace = try workspace(for: token)
        guard let textView = workspace.focusedEditor else { return "" }
        let range = textView.selectedRange()
        guard range.length > 0 else { return "" }
        return (textView.string as NSString).substring(with: range)
    }

    func notify(token: String?, message: String) throws {
        _ = try workspace(for: token)
        bannerToken = token
        banner = message
    }

    /// Presents a blocking prompt as a sheet on the *caller's* window.
    func askHuman(token: String?, question: String, options: [String]?) async throws -> String {
        let workspace = try workspace(for: token)
        let buttons = (options?.isEmpty == false) ? options! : ["OK"]
        guard let window = workspace.window else { return buttons[0] }
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

/// One find-and-replace edit for `propose_patch`.
struct ProposedEdit: Sendable, Codable {
    /// The exact text to find (include enough surrounding context to be unique).
    let oldString: String
    /// The text to replace it with.
    let newString: String
    /// Replace every occurrence instead of requiring a unique match.
    let replaceAll: Bool?
}

/// A tool-level failure with a message shown to the agent.
struct MCPToolFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct WeakWorkspace {
    weak var value: Workspace?
    let token: String
    init(_ value: Workspace, token: String) { self.value = value; self.token = token }
}
