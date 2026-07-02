import SwiftUI
import AppKit

/// The app's Settings window: editor preferences and the command-line tool.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Editor", systemImage: "textformat.size") {
                EditorSettingsView()
            }
            Tab("Command Line", systemImage: "terminal") {
                CommandLineSettingsView()
            }
        }
        .frame(width: 520, height: 380)
    }
}

private struct EditorSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var fontChoices: [String] = []

    var body: some View {
        @Bindable var settings = settings
        Form {
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
        .task { fontChoices = Self.monospacedFonts(including: settings.fontName) }
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
                Text("Ibis runs in the macOS sandbox and can't modify `/usr/local/bin` itself. Copy the command below, paste it into Terminal, and press Return — you'll be asked for your password.")
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
