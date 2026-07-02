import SwiftUI

/// The app's Settings window. Filled out with real controls (fonts, theme,
/// editor behavior, CLI install) in a later phase.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Text("Settings coming soon.")
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 520, height: 380)
    }
}
