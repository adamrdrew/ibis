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
        // Become the notification delegate so taps on an agent's desktop
        // notification raise the right project window (auth is deferred to the
        // first notification actually posted).
        DesktopNotifier.shared.configure()
    }

    /// Services menu handler: opens the file(s)/folder(s) the user selected
    /// (e.g. in Finder) as Ibis workspace windows. Declared as `openInIbis` in
    /// the Info.plist `NSServices` entry.
    @objc func openInIbis(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        // Only accept on-disk file URLs (a programmatic NSPerformService caller
        // could otherwise put an http: URL on the pasteboard and open a junk
        // workspace from its path), and only ones that actually exist.
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        var opened = false
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            LaunchRouter.shared.enqueue(WorkspaceRef(url: url, isDirectory: isDirectory.boolValue))
            opened = true
        }
        if opened {
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

    /// Confirm unsaved changes before the app quits (⌘Q / logout / shutdown).
    /// `NSApplication` termination never calls `windowShouldClose`, so without
    /// this every dirty editor in every window would be discarded silently.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirtyWorkspaces = Workspace.all.filter { !$0.dirtyDocuments.isEmpty }
        guard !dirtyWorkspaces.isEmpty else { return .terminateNow }
        // Ask each window in turn; a cancel (or failed save) aborts the quit.
        Task { @MainActor in
            for workspace in dirtyWorkspaces {
                let proceed = await workspace.confirmCloseForQuit()
                guard proceed else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
