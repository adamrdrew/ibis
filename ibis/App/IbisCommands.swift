import SwiftUI
import AppKit

/// Identifier for the main workspace window group, so menu commands can open
/// new windows.
let workspaceWindowID = "workspace"

/// Identifier for the singleton Welcome / launcher window.
let welcomeWindowID = "welcome"

/// The app's menu bar: File / View / Editor commands wired to the focused
/// window's `Workspace` (via `@FocusedValue`) and to the shared `AppSettings`.
/// Standard Edit (undo/cut/copy/paste), Find, and Sidebar commands come from
/// SwiftUI's built-in command groups.
struct IbisCommands: Commands {
    var settings: AppSettings

    @FocusedValue(\.activeWorkspace) private var workspace: Workspace?
    @FocusedValue(\.sidebarMode) private var sidebarMode: Binding<SidebarMode>?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: welcomeWindowID)
            }
            .keyboardShortcut("n")

            Divider()

            Button("Open File…") { open(choosingDirectories: false) }
                .keyboardShortcut("o")
            Button("Open Folder…") { open(choosingDirectories: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Save") {
                if let workspace { Task { await workspace.saveActiveDocument() } }
            }
            .keyboardShortcut("s")
            .disabled(workspace?.activeDocument?.isDirty != true)

            Button("Save As…") { workspace?.saveActiveDocumentAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace?.activeDocument == nil)

            Divider()

            Button("Reveal in Finder") { workspace?.revealActiveInFinder() }
                .disabled(workspace?.activeDocument == nil)
        }

        // Standard Edit menu Find/Replace/Spelling, routed to the focused editor.
        TextEditingCommands()

        // Show/Hide Sidebar.
        SidebarCommands()

        // MARK: View additions
        CommandGroup(after: .toolbar) {
            Button("Increase Font Size") {
                settings.fontSize = min(settings.fontSize + 1, 48)
            }
            .keyboardShortcut("+")

            Button("Decrease Font Size") {
                settings.fontSize = max(settings.fontSize - 1, 8)
            }
            .keyboardShortcut("-")

            Button("Actual Size") { settings.fontSize = 13 }
                .keyboardShortcut("0")

            Divider()

            Toggle("Show Line Numbers", isOn: boolBinding(\.showLineNumbers))
            Toggle("Wrap Lines", isOn: boolBinding(\.wordWrap))
        }

        // MARK: Editor
        CommandMenu("Editor") {
            Button("Split Editor") { workspace?.splitActiveEditor() }
                .keyboardShortcut("\\")
                .disabled(workspace?.activeDocument == nil)

            Divider()

            Button("Show Next Tab") { workspace?.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { workspace?.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            // ⌘W is handled by a key-window control in WorkspaceView so it can
            // take precedence over the built-in window Close command.
            Button("Close Tab") { workspace?.closeActiveTab() }
                .disabled(workspace?.activeDocument == nil)

            Divider()

            Button("Find in Folder…") { sidebarMode?.wrappedValue = .search }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }

        // MARK: Terminal
        CommandMenu("Terminal") {
            Button((workspace?.terminal.isVisible ?? false) ? "Hide Terminal" : "Show Terminal") {
                workspace?.toggleTerminal()
            }
            .keyboardShortcut(KeyEquivalent("`"), modifiers: .control)
            .disabled(workspace == nil)

            Button("New Terminal Tab") { workspace?.newTerminalTab() }
                .keyboardShortcut(KeyEquivalent("`"), modifiers: [.control, .shift])
                .disabled(workspace == nil)

            Button("Close Terminal Tab") { workspace?.closeActiveTerminalTab() }
                .disabled(workspace?.terminal.activeSessionID == nil)

            Divider()

            Button("Open in \(settings.agentName)") { runAgent() }
                .keyboardShortcut("a", modifiers: [.control, .shift])
                .disabled(workspace == nil || settings.agentCommandLine == nil)

            Divider()

            Button("Show Next Terminal") { workspace?.selectAdjacentTerminal(offset: 1) }
                .keyboardShortcut("]", modifiers: [.control, .shift])
                .disabled(workspace?.terminal.activeSessionID == nil)
            Button("Show Previous Terminal") { workspace?.selectAdjacentTerminal(offset: -1) }
                .keyboardShortcut("[", modifiers: [.control, .shift])
                .disabled(workspace?.terminal.activeSessionID == nil)

            Divider()

            Button(settings.terminalPlacement == .bottom ? "Move Terminal to the Right" : "Move Terminal to the Bottom") {
                settings.terminalPlacement = settings.terminalPlacement == .bottom ? .trailing : .bottom
            }
        }
    }

    // MARK: - Helpers

    private func runAgent() {
        guard let workspace, let command = settings.agentCommandLine else { return }
        workspace.runAgent(command: command, name: settings.agentName)
    }

    private func boolBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }

    private func open(choosingDirectories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !choosingDirectories
        panel.canChooseDirectories = choosingDirectories
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: WorkspaceRef(url: url, isDirectory: choosingDirectories))
    }
}
