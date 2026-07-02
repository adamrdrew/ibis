import SwiftUI

/// The Ibis application: a lightweight, folder-oriented text editor for developers.
///
/// Each window represents a *workspace* — either an opened folder or a single
/// opened file. A `nil` workspace shows the Welcome screen. The data-driven
/// `WindowGroup(for:)` gives us free multi-window support on macOS.
@main
struct IbisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup(for: WorkspaceRef.self) { $ref in
            WorkspaceRootView(ref: ref)
                .environment(settings)
                .tint(.ibisKelly)
        }

        Settings {
            SettingsView()
                .environment(settings)
                .tint(.ibisKelly)
        }
    }
}
