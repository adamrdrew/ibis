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
    /// The token of the workspace whose banner should show. Observed (not
    /// `@ObservationIgnored`): when the same message text is posted to a
    /// different window, this is the only value that changes — unobserved, no
    /// window would re-evaluate and the banner would stay on the wrong one.
    var bannerToken: String?
    /// Bumped on every `notify`, so the UI restarts its auto-dismiss timer even
    /// when the message text and token are both unchanged.
    private(set) var bannerEpoch = 0

    /// In-flight `ask_human` sheets by caller token. AppKit never invokes a
    /// sheet's completion handler when its window closes without `endSheet`, so
    /// window teardown resolves these explicitly via `cancelPrompts(for:)` —
    /// otherwise the checked continuation leaks and the MCP request hangs
    /// forever server-side.
    private final class PendingPrompt {
        var continuation: CheckedContinuation<String, any Error>?
    }
    private var pendingPrompts: [String: [PendingPrompt]] = [:]

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

    /// The project token of the workspace shown in `window`, if it is a
    /// workspace window. Lets `DesktopNotifier` clear a window's delivered
    /// notifications the moment the user brings it to the front themselves.
    func token(for window: NSWindow) -> String? {
        byToken.first { $0.value.value?.window === window }?.key
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

    /// Brings the window of the workspace bound to `token` to the front, used
    /// when the human taps a desktop notification an agent posted.
    func activateWindow(for token: String) {
        byToken[token]?.value?.window?.makeKeyAndOrderFront(nil)
    }

    /// Whether the workspace for `token` is the window the human is currently
    /// looking at. False when Ibis is in the background or another Ibis window is
    /// key — the signal for whether a `notify` also warrants a desktop ping.
    private func isForeground(_ workspace: Workspace) -> Bool {
        workspace.window != nil && workspace.window === NSApp.keyWindow
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
        let url = try resolvedURL(for: path, in: workspace)
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

    /// The text the diff should be computed against: the open buffer if the file
    /// is open (its unsaved edits are the current truth), else the file on disk.
    /// The disk read runs off the main actor — an agent can point this at any
    /// in-workspace file, including one big enough for a synchronous read to
    /// beachball the editor.
    private func currentContent(of url: URL, in workspace: Workspace) async -> String {
        if let open = workspace.openedDocument(for: url) { return open.text }
        return await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
    }

    /// Applies a set of `old → new` string edits to the current file content and
    /// runs the same diff review. Small, surgical edits stay cheap and still go
    /// through the approval gate. Errors are actionable so a mismatch is
    /// re-proposed through the gate rather than routed around it.
    func proposePatch(token: String?, path: String, edits: [ProposedEdit]) async throws -> String {
        let (workspace, url) = try target(token: token, path: path)
        let before = await currentContent(of: url, in: workspace)
        // The old→new scans are O(edits × size); run them off the main actor so
        // a patch against a huge file can't hang the editor before the diff is
        // even computed.
        let fileName = url.lastPathComponent
        let after = try await Task.detached(priority: .userInitiated) {
            try Self.applyEdits(edits, to: before, fileName: fileName)
        }.value
        return try await reviewAndApply(in: workspace, url: url, before: before, after: after)
    }

    // MARK: Edit helpers

    private func target(token: String?, path: String) throws -> (Workspace, URL) {
        let workspace = try workspace(for: token)
        return (workspace, try resolvedURL(for: path, in: workspace))
    }

    nonisolated private static func applyEdits(_ edits: [ProposedEdit], to content: String, fileName: String) throws -> String {
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
        // Myers diff is O((N+M)·D); a wholesale rewrite of a large file could
        // beachball the app for seconds. Compute it off the main actor.
        let proposal = await Task.detached(priority: .userInitiated) {
            LineDiff.proposal(fileURL: url, before: before, after: after)
        }.value
        guard let proposal else {
            return "No changes to \(url.lastPathComponent) — the result matches the current file."
        }
        guard workspace.pendingDiff == nil else {
            throw MCPToolFailure("A diff review is already open in this window; resolve it first.")
        }
        let approved = await workspace.awaitDiffDecision(proposal)
        if approved {
            // `replacing: before` re-validates on apply: the sheet can stay open
            // for minutes, and blindly writing the precomputed `after` would
            // silently revert anything that changed in the meantime.
            switch await workspace.applyProposedEdit(url: url, content: after, replacing: before) {
            case .applied:
                return "Applied changes to \(url.lastPathComponent) (+\(proposal.added) −\(proposal.removed))."
            case .staleContent:
                throw MCPToolFailure("\(url.lastPathComponent) changed while the diff was under review, so nothing was applied. Re-read the file and propose the edit again.")
            case .notWritable:
                throw MCPToolFailure("Couldn’t write \(url.lastPathComponent) — it may be read-only, binary, or on an unwritable volume. Nothing was changed.")
            case .saveFailed:
                throw MCPToolFailure("The approved change was applied to the open editor buffer, but saving \(url.lastPathComponent) to disk failed (read-only file? full volume?). The buffer now shows the change as unsaved; the file on disk is unchanged.")
            }
        }
        return "The human declined the changes to \(url.lastPathComponent)."
    }

    /// Opens agent-supplied content in a new, unsaved tab (no file). `format` is
    /// "markdown", "html", or "text"; when omitted it's inferred (HTML if the
    /// content looks like HTML, else Markdown).
    func openContent(token: String?, title: String, content: String, format: String?) throws -> String {
        let workspace = try workspace(for: token)
        let resolved = resolveFormat(format, content: content)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        let document = OpenDocument(title: name, text: content, format: resolved)
        workspace.layout.activePane?.open(document)
        return "Opened “\(name)” in a new tab."
    }

    private func resolveFormat(_ format: String?, content: String) -> OpenDocument.Format {
        switch format?.lowercased() {
        case "markdown", "md": return .markdown
        case "html", "htm": return .html
        case "text", "plain", "source": return .source
        case .some(let other) where !other.isEmpty:
            return .markdown // unknown explicit value → safest renderable default
        default:
            // Inferred fallback: only call it HTML on a strong signal.
            let head = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).lowercased()
            if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.contains("<body") {
                return .html
            }
            return .markdown
        }
    }

    func revealInTree(token: String?, path: String) throws -> String {
        let workspace = try workspace(for: token)
        let url = try resolvedURL(for: path, in: workspace)
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
        let workspace = try workspace(for: token)
        bannerToken = token
        banner = message
        bannerEpoch += 1
        // The banner only helps if the human is looking at this window. When
        // they aren't, ping the desktop so they know to come back to it.
        if !isForeground(workspace) {
            DesktopNotifier.shared.post(
                title: "Ibis — \(workspace.displayName)", body: message, token: token
            )
        }
    }

    /// Presents a blocking prompt as a sheet on the *caller's* window.
    func askHuman(token: String?, question: String, options: [String]?) async throws -> String {
        let workspace = try workspace(for: token)
        let buttons = (options?.isEmpty == false) ? options! : ["OK"]
        // No window → no way to actually ask; failing is honest, fabricating a
        // choice (e.g. "yes" to a destructive confirmation) is not.
        guard let window = workspace.window else { throw MCPBridgeError.noWindow }
        // The prompt is a sheet on this one window; if the human is elsewhere it
        // would sit unnoticed, blocking the agent. Ping the desktop to draw them
        // back — tapping it raises this window and reveals the sheet.
        if !isForeground(workspace) {
            DesktopNotifier.shared.post(
                title: "Ibis — \(workspace.displayName)",
                body: "The agent is asking: \(question)", token: token
            )
        }
        let key = token ?? ""
        let pending = PendingPrompt()
        pendingPrompts[key, default: []].append(pending)
        return try await withCheckedThrowingContinuation { continuation in
            pending.continuation = continuation
            let alert = NSAlert()
            alert.messageText = "The agent is asking:"
            alert.informativeText = question
            for button in buttons { alert.addButton(withTitle: button) }
            alert.beginSheetModal(for: window) { [weak self] response in
                // Already resolved by `cancelPrompts` (the window closed).
                guard let resumable = pending.continuation else { return }
                pending.continuation = nil
                self?.pendingPrompts[key]?.removeAll { $0 === pending }
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                let choice = buttons.indices.contains(index) ? buttons[index] : buttons[0]
                resumable.resume(returning: choice)
            }
        }
    }

    /// Resolves every in-flight `ask_human` for a closing workspace window, so
    /// the agent gets an honest error instead of hanging forever.
    func cancelPrompts(for workspace: Workspace) {
        let key = token(for: workspace)
        guard let prompts = pendingPrompts.removeValue(forKey: key) else { return }
        for pending in prompts {
            pending.continuation?.resume(
                throwing: MCPToolFailure("The window closed before the human answered.")
            )
            pending.continuation = nil
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

    /// Resolves a tool-supplied path and *requires* it to be inside the
    /// workspace root. An agent (or anyone holding its token) must not be able to
    /// read/write arbitrary files (`~/.ssh/config`, `~/.zshrc`, …) — including
    /// via a substring-presence oracle from `propose_patch` error messages — so
    /// the containment check happens before any file is touched.
    private func resolvedURL(for path: String, in workspace: Workspace) throws -> URL {
        let url = resolve(path, in: workspace)
        let rootPath = workspace.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw MCPToolFailure("“\(path)” is outside this project. Ibis only exposes files within the open workspace folder.")
        }
        return url
    }
}

/// One find-and-replace edit for `propose_patch`. `nonisolated` so its Codable
/// conformance stays usable from the nonisolated `@MCPTool`-generated decoding
/// (under MainActor default isolation the conformance would be isolated).
nonisolated struct ProposedEdit: Sendable, Codable {
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
