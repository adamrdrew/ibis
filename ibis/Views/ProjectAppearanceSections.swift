import SwiftUI
import AppKit

/// The Project Settings sheet's appearance controls: per-project overrides for
/// the editor themes, the terminal themes, and the window accent. Every control
/// offers a "Default" state that falls through to Settings ▸ Editor / Terminal,
/// and each falls through independently — overriding the dark editor theme
/// leaves the light one (and both terminal themes) following the app.
///
/// Edits mutate the live `ProjectConfig`, so the window re-themes as you change
/// them; the sheet's Done writes them to `.ibis.json` and Cancel reloads.
struct ProjectAppearanceSections: View {
    @Bindable var config: ProjectConfig

    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    @State private var editorThemeChoices: [String] = []

    var body: some View {
        // Accent first: it's two compact rows, and burying it under two 160pt
        // theme previews would put it off-screen in the sheet.
        accentSection
        editorSection
        terminalSection
    }

    // MARK: - Editor

    private var editorSection: some View {
        Section {
            themePicker(
                "Light Mode",
                selection: $config.appearance.editorLightTheme,
                choices: editorThemeChoices,
                appDefault: settings.lightTheme)
            themePicker(
                "Dark Mode",
                selection: $config.appearance.editorDarkTheme,
                choices: editorThemeChoices,
                appDefault: settings.darkTheme)

            // One preview, for the appearance the Mac is currently in — two
            // 160pt samples per section would push everything else off-screen.
            EditorThemePreview(
                themeName: colorScheme == .dark
                    ? effectiveAppearance.editorDarkTheme
                    : effectiveAppearance.editorLightTheme,
                fontName: settings.fontName,
                fontSize: settings.fontSize)
        } header: {
            Text("Editor Theme")
        } footer: {
            Text("Applies to this project’s windows, and is saved in .ibis.json (which Ibis keeps out of git). “Default” follows Settings ▸ Editor.")
        }
        .task {
            var themes = await SyntaxHighlighter.shared.availableThemes()
            // Keep a hand-edited or since-removed theme name selectable, or the
            // picker would silently snap the project to something else.
            for required in [config.appearance.editorLightTheme, config.appearance.editorDarkTheme]
            where required != nil && !themes.contains(required!) {
                themes.append(required!)
            }
            editorThemeChoices = themes.sorted()
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        Section {
            themePicker(
                "Light Mode",
                selection: $config.appearance.terminalLightTheme,
                choices: TerminalThemeCatalog.light.map(\.name),
                appDefault: settings.terminalLightTheme)
            themePicker(
                "Dark Mode",
                selection: $config.appearance.terminalDarkTheme,
                choices: TerminalThemeCatalog.dark.map(\.name),
                appDefault: settings.terminalDarkTheme)

            TerminalThemePreview(
                theme: effectiveAppearance.terminalTheme(isDark: colorScheme == .dark),
                fontName: settings.terminalFontName,
                fontSize: settings.terminalFontSize)
        } header: {
            Text("Terminal Theme")
        } footer: {
            Text("Applies to this project’s terminals, including ones already open. “Default” follows Settings ▸ Terminal.")
        }
    }

    // MARK: - Accent

    private var accentSection: some View {
        Section {
            Toggle("Custom Accent Color", isOn: accentEnabled)

            if config.appearance.accent != nil {
                ColorPicker("Accent Color", selection: accentColor, supportsOpacity: false)
                AccentPreview(accent: effectiveAppearance.accentColor)
            }
        } header: {
            Text("Accent Color")
        } footer: {
            Text("Tints this project’s window only — folder icons, the active tab and pane markers, the caret, and buttons. Useful for telling several open projects apart at a glance.")
        }
    }

    /// Turning the override on seeds it with the accent currently in force, so
    /// the color well opens on today's color instead of an arbitrary one.
    private var accentEnabled: Binding<Bool> {
        Binding(
            get: { config.appearance.accent != nil },
            set: { isOn in
                config.appearance.accent = isOn ? ThemeColor(nsColor: .ibisAccent) : nil
            })
    }

    private var accentColor: Binding<Color> {
        Binding(
            get: { effectiveAppearance.accentColor },
            set: { config.appearance.accent = ThemeColor(nsColor: NSColor($0)) })
    }

    // MARK: - Shared

    /// What the window renders with right now, given the (unsaved) overrides —
    /// the same resolution the workspace uses, so the previews match reality.
    private var effectiveAppearance: EffectiveAppearance {
        EffectiveAppearance.resolve(
            project: config.appearance, defaults: settings.appearanceDefaults)
    }

    /// A picker whose nil selection means "no override", labelled with the
    /// app-wide value it falls through to.
    private func themePicker(
        _ title: String,
        selection: Binding<String?>,
        choices: [String],
        appDefault: String
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Default (\(appDefault))").tag(String?.none)
            Divider()
            ForEach(choices, id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        }
    }
}

/// A miniature of the chrome an accent touches, so the color can be judged
/// without closing the sheet.
private struct AccentPreview: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder")
                .foregroundStyle(accent)
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text("ContentView.swift")
                    .font(.callout)
            }
            Spacer(minLength: 0)
            Button("Done") {}
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .allowsHitTesting(false)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

#Preview("Project appearance") {
    // Seeded with an accent override so the color well and its sample render.
    let config = ProjectConfig(root: FileManager.default.temporaryDirectory)
    config.appearance.accent = ThemeColor(hex: "#ff8800")
    return Form {
        ProjectAppearanceSections(config: config)
    }
    .formStyle(.grouped)
    .environment(AppSettings())
    .frame(width: 560, height: 620)
}
