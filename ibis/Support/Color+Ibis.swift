import SwiftUI
import AppKit

extension Color {
    /// Ibis's hero color — kelly green. It's the value of the `AccentColor`
    /// asset, so it's what the app tints with when the system accent is set to
    /// "Multicolor" (the default). When the user picks an explicit system accent
    /// the system overrides the asset, so prefer ``ibisAccent`` for anything that
    /// should follow the user's choice.
    static let ibisKelly = Color(.sRGB, red: 0.298, green: 0.733, blue: 0.090, opacity: 1)

    /// The app's accent color, honoring the system accent color choice and
    /// updating live when it changes. `Color.accentColor` resolves to the user's
    /// explicit system accent when one is set, and to the `AccentColor` asset
    /// (kelly) when the accent is "Multicolor".
    static var ibisAccent: Color { .accentColor }
}

extension NSColor {
    /// AppKit twin of ``Color/ibisAccent``. AppKit doesn't override an asset with
    /// the system accent the way SwiftUI does, so resolve it explicitly: the
    /// user's accent when one is chosen, kelly when the accent is "Multicolor".
    ///
    /// Unlike SwiftUI, a resolved `NSColor` assigned to a view is cached, so call
    /// sites must re-read this on `NSColor.systemColorsDidChangeNotification` to
    /// stay live.
    static var ibisAccent: NSColor {
        // "Multicolor" leaves `AppleAccentColor` unset in the global domain; any
        // explicit accent choice writes an integer there.
        let hasExplicitAccent = UserDefaults.standard.object(forKey: "AppleAccentColor") != nil
        return hasExplicitAccent ? .controlAccentColor : NSColor(Color.ibisKelly)
    }
}
