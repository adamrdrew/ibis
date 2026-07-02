import AppKit

/// Bridges AppKit application events into SwiftUI. Handles files and folders
/// opened from Finder or the `ibis` command-line tool (`open -a Ibis <path>`),
/// routing each to a new workspace window via `LaunchRouter`.
final class AppDelegate: NSObject, NSApplicationDelegate {
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
