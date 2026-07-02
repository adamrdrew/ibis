import AppKit

/// Bridges AppKit application events into SwiftUI. Handles files and folders
/// opened from Finder or the `ibis` command-line tool (`open -a Ibis <path>`),
/// routing each to a new workspace window via `LaunchRouter`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Advertise what the app can hand to Services (and macOS intelligence
        // "Ask"/Writing Tools items) so they appear in the file browser's menu.
        NSApp.registerServicesMenuSendTypes([.string, .fileURL], returnTypes: [])
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            LaunchRouter.shared.enqueue(WorkspaceRef(url: url, isDirectory: isDirectory))
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
