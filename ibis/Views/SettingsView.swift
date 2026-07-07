import SwiftUI
import AppKit

/// The app's Settings window: editor preferences and the command-line tool.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Editor", systemImage: "textformat.size") {
                EditorSettingsView()
            }
            Tab("Terminal", systemImage: "terminal") {
                TerminalSettingsView()
            }
            Tab("Agent", systemImage: "sparkles") {
                AgentSettingsView()
            }
            Tab("Command Line", systemImage: "command") {
                CommandLineSettingsView()
            }
        }
        .frame(width: 520, height: 380)
    }
}

private struct EditorSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var fontChoices: [String] = []
    @State private var themeChoices: [String] = []

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Theme") {
                Picker("Light Mode", selection: $settings.lightTheme) {
                    ForEach(themeChoices, id: \.self) { Text($0).tag($0) }
                }
                Picker("Dark Mode", selection: $settings.darkTheme) {
                    ForEach(themeChoices, id: \.self) { Text($0).tag($0) }
                }
            }

            Section("Font") {
                Picker("Typeface", selection: $settings.fontName) {
                    ForEach(fontChoices, id: \.self) { Text($0).tag($0) }
                }
                Stepper(
                    "Size: \(Int(settings.fontSize)) pt",
                    value: $settings.fontSize,
                    in: 9...32
                )
            }

            Section("Indentation") {
                Stepper(
                    "Tab Width: \(settings.tabWidth) spaces",
                    value: $settings.tabWidth,
                    in: 2...8
                )
                Toggle("Insert Spaces for Tabs", isOn: $settings.usesSoftTabs)
            }

            Section("Display") {
                Toggle("Show Line Numbers", isOn: $settings.showLineNumbers)
                Toggle("Wrap Lines", isOn: $settings.wordWrap)
            }

            Section("Project Settings File") {
                Picker("Opening “.ibis.json”", selection: Binding(
                    get: { ProjectConfigOpenStore.globalDefault },
                    set: { ProjectConfigOpenStore.globalDefault = $0 }
                )) {
                    ForEach(IbisConfigOpenBehavior.allCases) { Text($0.displayName).tag($0) }
                }
                Text("What happens when you open a project’s .ibis.json. A project can override this by choosing “Remember my choice” in the prompt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            fontChoices = Self.monospacedFonts(including: settings.fontName)
            var themes = await SyntaxHighlighter.shared.availableThemes()
            for required in [settings.lightTheme, settings.darkTheme] where !themes.contains(required) {
                themes.append(required)
            }
            themeChoices = themes.sorted()
        }
    }

    /// Monospaced font families available on the system, plus the current choice.
    static func monospacedFonts(including current: String) -> [String] {
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch ?? false
        }
        return Array(Set(families).union([current])).sorted()
    }
}

private struct TerminalSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var fontChoices: [String] = []

    /// The shell that will be used when the override field is left blank.
    private var defaultShell: String {
        ShellResolver.resolve(override: nil).executable
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Layout") {
                Picker("Position", selection: $settings.terminalPlacement) {
                    Text("Bottom").tag(TerminalPlacement.bottom)
                    Text("Right").tag(TerminalPlacement.trailing)
                }
                .pickerStyle(.segmented)
            }

            Section("Font") {
                Picker("Typeface", selection: $settings.terminalFontName) {
                    ForEach(fontChoices, id: \.self) { Text($0).tag($0) }
                }
                Stepper(
                    "Size: \(Int(settings.terminalFontSize)) pt",
                    value: $settings.terminalFontSize,
                    in: 9...32
                )
            }

            Section("Shell") {
                TextField("Shell Path", text: $settings.terminalShellPath, prompt: Text(defaultShell))
                    .font(.system(.body, design: .monospaced))

                HStack {
                    Button("Choose…") { chooseShell() }
                    if !settings.terminalShellPath.isEmpty {
                        Button("Use Default") { settings.terminalShellPath = "" }
                    }
                    Spacer()
                }

                Text("Leave blank to use your login shell (\(defaultShell)). Launched as a login shell. Changes apply to newly opened terminals.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            fontChoices = EditorSettingsView.monospacedFonts(including: settings.terminalFontName)
        }
    }

    private func chooseShell() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/bin")
        panel.prompt = "Choose Shell"
        if panel.runModal() == .OK, let url = panel.url {
            settings.terminalShellPath = url.path(percentEncoded: false)
        }
    }
}

private struct AgentSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Agent") {
                TextField("Name", text: $settings.agentName, prompt: Text("Claude"))
                TextField("Command", text: $settings.agentCommand, prompt: Text("claude"))
                    .font(.system(.body, design: .monospaced))
                TextField("Arguments", text: $settings.agentArgs, prompt: Text("optional, e.g. --model opus"))
                    .font(.system(.body, design: .monospaced))
                Text("Runs in a new terminal at the workspace folder via “Open in \(settings.agentName)” (⌃⇧A) or the toolbar. Launched through a login shell so your PATH applies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Configuration Format") {
                Picker("Your Agent", selection: $settings.agentKind) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Determines which config file format Ibis writes below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("MCP Server") {
                if MCPService.isAvailable {
                    Toggle("Enable MCP Server", isOn: $settings.mcpEnabled)
                        .onChange(of: settings.mcpEnabled) { _, _ in MCPService.apply(settings: settings) }

                    LabeledContent("Status") {
                        if let port = MCPService.runningPort {
                            // `\(String(port))` keeps LocalizedStringKey from
                            // formatting the port as a number (which inserts a
                            // grouping comma: "4,319").
                            Label("Running on 127.0.0.1:\(String(port))", systemImage: "circle.fill")
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        } else if let error = MCPService.startError, settings.mcpEnabled {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Text("Stopped").foregroundStyle(.secondary)
                        }
                    }

                    TextField("Preferred Port (0 = automatic)", value: $settings.mcpPort, format: .number.grouping(.never))
                        .onChange(of: settings.mcpPort) { _, _ in
                            if settings.mcpEnabled { MCPService.restart(settings: settings) }
                        }

                    Toggle("Inject Ibis system prompt (Claude Code)", isOn: $settings.agentInjectSystemPrompt)

                    Text("Lets your agent drive and read its own project window. Each project gets a unique token, so an agent can only reach the window it was launched in. Bound to localhost only. The system prompt tells Claude Code it is running in Ibis and how to use its tools; it is appended at launch via --append-system-prompt.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The SwiftMCP package isn't linked in this build, so the server is unavailable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("To connect an individual project, add the Ibis server to it from that project’s Project Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CommandLineSettingsView: View {
    @State private var copied = false

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.adamrdrew.Ibis"
    }

    private var installCommand: String {
        "sudo mkdir -p /usr/local/bin && "
        + "printf '#!/bin/sh\\nopen -b \(bundleIdentifier) \"$@\"\\n' | "
        + "sudo tee /usr/local/bin/ibis >/dev/null && "
        + "sudo chmod +x /usr/local/bin/ibis"
    }

    var body: some View {
        Form {
            Section {
                Text("Open a folder from the terminal in Ibis:")
                Text("ibis .")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("Install") {
                Text("Installing to `/usr/local/bin` needs administrator rights. Copy the command below, paste it into a terminal, and press Return — you'll be asked for your password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(installCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                Button {
                    copyInstallCommand()
                } label: {
                    Label(copied ? "Copied" : "Copy Install Command",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
