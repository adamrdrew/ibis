import SwiftUI

extension Color {
    /// Ibis's hero color — kelly green. Used sparingly, for deliberate brand
    /// marks (the editor insertion point, active-pane indicator, folder tint,
    /// status dot, terminal accents). It's also the `AccentColor` asset's
    /// default value, so control tinting follows the user's chosen system
    /// accent and falls back to kelly.
    static let ibisKelly = Color(.sRGB, red: 0.298, green: 0.733, blue: 0.090, opacity: 1)
}
