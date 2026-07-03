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
