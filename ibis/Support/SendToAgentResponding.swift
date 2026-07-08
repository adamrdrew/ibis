import AppKit
import Observation

/// Implemented by the AppKit views a user can select in — the code editor, the
/// integrated terminal, and the file browser — so a single "Send to Agent"
/// menu-bar command and its keyboard shortcut can act on whichever one holds
/// focus. `IbisCommands` dispatches `ibisSendSelectionToAgent(_:)` down the
/// responder chain (`NSApp.sendAction(_:to:nil:from:)`); the first responder
/// that conforms extracts its own selection and delivers it to the agent. The
/// same selector backs each view's right-click menu item.
@objc protocol SendToAgentResponding: AnyObject {
    @objc func ibisSendSelectionToAgent(_ sender: Any?)

    /// Whether this surface currently has something selected to send, so the
    /// menu command can disable itself when there's nothing to send.
    @objc var hasAgentSelection: Bool { get }
}

/// Bumps a revision whenever a menu begins tracking, giving SwiftUI's `Commands`
/// a reason to re-evaluate command `disabled` state at menu-open time. Used so
/// "Send Selection to Agent" can reflect the *live* first-responder selection —
/// which isn't observable through SwiftUI on its own.
@MainActor
@Observable
final class MenuActivation {
    static let shared = MenuActivation()
    private(set) var revision = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision &+= 1 }
        }
    }
}
