import Testing
import Foundation
import AppKit
@testable import Ibis

@MainActor
@Suite struct ProjectAppearanceTests {
    // MARK: - Fall-through

    private var appDefaults: EffectiveAppearance {
        EffectiveAppearance(
            editorLightTheme: "app-light",
            editorDarkTheme: "app-dark",
            terminalLightTheme: "App Terminal Light",
            terminalDarkTheme: "App Terminal Dark",
            accent: nil)
    }

    @Test func noOverridesYieldTheAppDefaults() {
        let resolved = EffectiveAppearance.resolve(project: .none, defaults: appDefaults)
        #expect(resolved == appDefaults)
    }

    @Test func eachFieldFallsThroughIndependently() {
        var project = ProjectAppearance.none
        project.editorDarkTheme = "nord"
        let resolved = EffectiveAppearance.resolve(project: project, defaults: appDefaults)

        #expect(resolved.editorDarkTheme == "nord")
        // The three untouched fields still follow the app-wide settings.
        #expect(resolved.editorLightTheme == "app-light")
        #expect(resolved.terminalLightTheme == "App Terminal Light")
        #expect(resolved.terminalDarkTheme == "App Terminal Dark")
        #expect(resolved.accent == nil)
    }

    @Test func projectAccentReplacesTheAppAccent() {
        var project = ProjectAppearance.none
        project.accent = ThemeColor(hex: "#ff8800")
        let resolved = EffectiveAppearance.resolve(project: project, defaults: appDefaults)
        #expect(resolved.accent == ThemeColor(hex: "#ff8800"))
        #expect(resolved.accentNSColor == ThemeColor(hex: "#ff8800")?.nsColor)
    }

    @Test func settingsDefaultsCarryNoAccentOverride() {
        let settings = AppSettings()
        let defaults = settings.appearanceDefaults
        #expect(defaults.editorLightTheme == settings.lightTheme)
        #expect(defaults.terminalDarkTheme == settings.terminalDarkTheme)
        #expect(defaults.accent == nil)
    }

    // MARK: - Color round-tripping

    @Test func themeColorRoundTripsThroughHex() {
        let color = ThemeColor(hex: "#3f7ad0")
        #expect(color?.hexString == "#3f7ad0")
        #expect(ThemeColor(hex: color!.hexString) == color)
    }

    @Test func themeColorFromNSColorConvertsToSRGB() {
        let color = ThemeColor(nsColor: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        #expect(color.hexString == "#ff8000")
    }

    // MARK: - `.ibis.json` persistence

    @Test func appearanceRoundTripsThroughTheConfigFile() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.appearance.editorDarkTheme = "nord"
            config.appearance.terminalLightTheme = "Ibis Light"
            config.appearance.accent = ThemeColor(hex: "#ff8800")
            try config.save()

            let reloaded = ProjectConfig(root: dir)
            #expect(reloaded.loadError == nil)
            #expect(reloaded.appearance.editorDarkTheme == "nord")
            #expect(reloaded.appearance.editorLightTheme == nil)
            #expect(reloaded.appearance.terminalLightTheme == "Ibis Light")
            #expect(reloaded.appearance.accent == ThemeColor(hex: "#ff8800"))
        }
    }

    @Test func clearingEveryOverrideRemovesTheAppearanceKey() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.appearance.editorDarkTheme = "nord"
            try config.save()

            config.appearance = .none
            try config.save()

            let raw = try String(contentsOf: dir.appending(path: ".ibis.json"), encoding: .utf8)
            #expect(raw.contains("appearance") == false)
            #expect(ProjectConfig(root: dir).appearance.isEmpty)
        }
    }

    @Test func malformedAppearanceValuesDegradeToNoOverride() throws {
        try TestSupport.withTempDir { dir in
            // A hand-edited file with a non-string theme, a blank one, and a bad
            // hex color must still load — those fields just fall through.
            let raw = """
                {"appearance": {"editorDarkTheme": 42, "editorLightTheme": "   ",
                 "accentColor": "not-a-color", "terminalDarkTheme": "Ibis Dark"}}
                """
            try raw.write(to: dir.appending(path: ".ibis.json"), atomically: true, encoding: .utf8)

            let config = ProjectConfig(root: dir)
            #expect(config.loadError == nil)
            #expect(config.appearance.editorDarkTheme == nil)
            #expect(config.appearance.editorLightTheme == nil)
            #expect(config.appearance.accent == nil)
            #expect(config.appearance.terminalDarkTheme == "Ibis Dark")
        }
    }

    @Test func appearanceAloneIsNotExecutableContent() throws {
        try TestSupport.withTempDir { dir in
            let config = ProjectConfig(root: dir)
            config.appearance.accent = ThemeColor(hex: "#ff0000")
            // Themes are inert data, so a folder carrying only them must not
            // raise the trust prompt.
            #expect(config.hasExecutableContent == false)
        }
    }

    @Test func appearanceSurvivesAlongsideActionsAndUnknownKeys() throws {
        try TestSupport.withTempDir { dir in
            let original = #"{"futureSetting": true, "appearance": {"editorDarkTheme": "nord"}}"#
            try original.write(to: dir.appending(path: ".ibis.json"), atomically: true, encoding: .utf8)

            let config = ProjectConfig(root: dir)
            config.actions = [ProjectConfig.Action(name: "Build", command: "make")]
            try config.save()

            let reloaded = ProjectConfig(root: dir)
            #expect(reloaded.appearance.editorDarkTheme == "nord")
            #expect(reloaded.actions.first?.command == "make")
            let raw = try String(contentsOf: dir.appending(path: ".ibis.json"), encoding: .utf8)
            #expect(raw.contains("futureSetting"))
        }
    }
}
