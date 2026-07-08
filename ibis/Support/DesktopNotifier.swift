import AppKit
import UserNotifications

/// Posts macOS desktop notifications on behalf of the MCP tools, so an agent can
/// get the human's attention even when they're looking at a different window (or
/// another app entirely). A tap raises the project window the notification came
/// from — the "many windows, poll each one" workflow the banners alone don't
/// solve. See [[unified-split-terminal]] for the window/pane model these route to.
///
/// Authorization is requested lazily on the first `post`, not at launch, so a
/// user who never triggers an agent notification never sees the system prompt.
@MainActor
final class DesktopNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DesktopNotifier()
    private override init() { super.init() }

    /// userInfo key carrying the project token of the window to raise on tap.
    private static let tokenKey = "ibisProjectToken"

    /// Whether we've already asked the system for authorization this run.
    private var didRequestAuthorization = false

    /// Whether the UserNotifications machinery is safe to touch in this process.
    /// `UNUserNotificationCenter.current()` reaches the `usernoted` daemon, which
    /// doesn't exist under the test runner (its app host launches on a headless
    /// CI agent with no notification service) — touching it there blocks the host
    /// launch and hangs the whole test suite. Also false when unbundled, where
    /// the notification center traps. Mirrors the `XCTestCase` guard the app
    /// already uses to skip test-hostile launch side effects.
    static var isUsable: Bool {
        Bundle.main.bundleIdentifier != nil && NSClassFromString("XCTestCase") == nil
    }

    /// Becomes this process's notification delegate. Call once at launch, before
    /// any notification could be delivered, so taps route through `didReceive`.
    /// Requesting authorization is deferred to the first `post`.
    func configure() {
        guard Self.isUsable else { return }
        UNUserNotificationCenter.current().delegate = self
        // A window coming to the front makes its pending "come look at this
        // window" banners moot — clear them so Notification Center doesn't
        // pile up stale pings the user already answered by switching over.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard Bundle.main.bundleIdentifier != nil,
              let window = note.object as? NSWindow,
              let token = MCPBridge.shared.token(for: window) else { return }
        clearDelivered(token: token)
    }

    /// Removes delivered notifications that pointed at `token`'s window.
    private func clearDelivered(token: String) {
        let key = Self.tokenKey
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { ($0.request.content.userInfo[key] as? String) == token }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Posts a desktop notification. `token` is stashed so a tap can raise that
    /// project's window. No-op if the app is unbundled (no bundle id → the
    /// notification center is unavailable and would trap).
    func post(title: String, body: String, token: String?) {
        guard Self.isUsable else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let token { content.userInfo = [Self.tokenKey: token] }

        // nil trigger → deliver immediately.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even while Ibis is the active app — the point is to flag a
    /// window the human *isn't* looking at, which is common with several Ibis
    /// windows open at once.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tap activates Ibis and brings the originating project window to the
    /// front, so the human lands on the agent that pinged them.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let token = response.notification.request.content.userInfo[Self.tokenKey] as? String
        NSApp.activate(ignoringOtherApps: true)
        if let token { MCPBridge.shared.activateWindow(for: token) }
    }
}
