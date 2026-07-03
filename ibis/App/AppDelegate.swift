import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Bridges AppKit application events into SwiftUI. Handles files and folders
/// opened from Finder or the `ibis` command-line tool (`open -a Ibis <path>`),
/// routing each to a new workspace window via `LaunchRouter`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if canImport(Sparkle)
    /// Drives auto-updates. Active only once the Sparkle package is added to the
    /// target (see the SUFeedURL / SUPublicEDKey keys in Info.plist).
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Advertise what the app can hand to Services (and macOS intelligence
        // "Ask"/Writing Tools items) so they appear in the file browser's menu.
        NSApp.registerServicesMenuSendTypes([.string, .fileURL], returnTypes: [])
        // Provide the "Open in Ibis" service (declared in Info.plist NSServices).
        NSApp.servicesProvider = self
    }

    /// Services menu handler: opens the file(s)/folder(s) the user selected
    /// (e.g. in Finder) as Ibis workspace windows. Declared as `openInIbis` in
    /// the Info.plist `NSServices` entry.
    @objc func openInIbis(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            LaunchRouter.shared.enqueue(WorkspaceRef(url: url, isDirectory: isDirectory))
        }
        if !urls.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
        }
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
