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
        // The launcher: a compact, content-sized, non-resizable window shown at
        // startup. It's the app's primary scene, so it opens on a plain launch.
        Window("Welcome to Ibis", id: welcomeWindowID) {
            WelcomeView()
                .environment(settings)
                .tint(.ibisKelly)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        // Editor windows, one per opened folder/file, at a roomy 4:3 default.
        WindowGroup(id: workspaceWindowID, for: WorkspaceRef.self) { $ref in
            WorkspaceRootView(ref: ref)
                .environment(settings)
                .tint(.ibisKelly)
        }
        .defaultSize(width: 1280, height: 960)
        .commands {
            IbisCommands(settings: settings)
        }

        Settings {
            SettingsView()
                .environment(settings)
                .tint(.ibisKelly)
        }
    }
}
