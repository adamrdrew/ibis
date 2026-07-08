import Testing
import Foundation
import SwiftTerm
@testable import Ibis

@Suite struct ThemeColorTests {
    @Test func parsesSixDigitHex() {
        let color = ThemeColor(hex: "#ff8000")
        #expect(color != nil)
        #expect(abs((color?.red ?? 0) - 1.0) < 0.001)
        #expect(abs((color?.green ?? 0) - 0.502) < 0.01)
        #expect((color?.blue ?? 1) == 0.0)
    }

    @Test func parsesShorthandHexAndTolueratesMissingHash() {
        let withHash = ThemeColor(hex: "#fff")
        let without = ThemeColor(hex: "ffffff")
        #expect(withHash?.red == 1.0)
        #expect(withHash?.green == 1.0)
        #expect(withHash?.blue == 1.0)
        #expect(without?.red == 1.0)
    }

    @Test func rejectsMalformedHex() {
        #expect(ThemeColor(hex: "#12") == nil)
        #expect(ThemeColor(hex: "nothex") == nil)
        #expect(ThemeColor(hex: "#gggggg") == nil)
    }

    @Test func bridgesToSwiftTermColorAtFullScale() {
        let white = ThemeColor(hex: "#ffffff")?.swiftTermColor
        let black = ThemeColor(hex: "#000000")?.swiftTermColor
        #expect(white?.red == 65535)
        #expect(white?.green == 65535)
        #expect(white?.blue == 65535)
        #expect(black?.red == 0)
    }
}

@Suite struct TerminalThemeCatalogTests {
    /// A minimal valid catalog payload for parse tests.
    private static let json = """
        [
          {
            "name": "Test Dark",
            "isDark": true,
            "background": "#000000",
            "foreground": "#ffffff",
            "cursor": "#ffffff",
            "cursorText": "#000000",
            "selection": "#333333",
            "ansi": [
              "#000000", "#111111", "#222222", "#333333",
              "#444444", "#555555", "#666666", "#777777",
              "#888888", "#999999", "#aaaaaa", "#bbbbbb",
              "#cccccc", "#dddddd", "#eeeeee", "#ffffff"
            ]
          }
        ]
        """

    @Test func decodesAWellFormedTheme() throws {
        let themes = try TerminalThemeCatalog.decode(from: Data(Self.json.utf8))
        #expect(themes.count == 1)
        let theme = try #require(themes.first)
        #expect(theme.name == "Test Dark")
        #expect(theme.isDark)
        #expect(theme.ansi.count == 16)
        #expect(theme.cursorText != nil)
    }

    @Test func dropsThemesWithoutAFullPalette() throws {
        let short = """
            [{ "name": "Bad", "isDark": true, "background": "#000000",
               "foreground": "#ffffff", "cursor": "#ffffff", "selection": "#333333",
               "ansi": ["#000000", "#111111"] }]
            """
        let themes = try TerminalThemeCatalog.decode(from: Data(short.utf8))
        #expect(themes.isEmpty)
    }

    @Test func bundledCatalogIsUsableAndClassified() {
        // The app bundle isn't loaded under the test host, so this exercises the
        // hardcoded fallbacks when the resource is absent, and the parsed catalog
        // when it is — either way the invariants must hold.
        #expect(!TerminalThemeCatalog.all.isEmpty)
        #expect(!TerminalThemeCatalog.light.isEmpty)
        #expect(!TerminalThemeCatalog.dark.isEmpty)
        #expect(TerminalThemeCatalog.all.allSatisfy { $0.ansi.count == 16 })
        #expect(TerminalThemeCatalog.light.allSatisfy { !$0.isDark })
        #expect(TerminalThemeCatalog.dark.allSatisfy { $0.isDark })
    }

    @Test func fallsBackWhenNameIsUnknown() {
        let dark = TerminalThemeCatalog.theme(named: "does-not-exist", isDark: true)
        let light = TerminalThemeCatalog.theme(named: "does-not-exist", isDark: false)
        #expect(dark.isDark)
        #expect(!light.isDark)
    }

    @Test func resolvesKnownFallbackByName() {
        let theme = TerminalThemeCatalog.theme(named: "Ibis Dark", isDark: true)
        #expect(theme.name == "Ibis Dark")
        #expect(theme.ansi.count == 16)
    }
}
