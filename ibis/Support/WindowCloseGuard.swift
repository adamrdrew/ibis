import SwiftUI
import AppKit

/// Installs an `NSWindowDelegate` on the hosting window that can veto closing
/// (via `shouldClose`) — e.g. to confirm unsaved changes. All other delegate
/// methods are forwarded to SwiftUI's own window delegate so scene management
/// keeps working.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeCoordinator() -> Proxy { Proxy(shouldClose: shouldClose) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { context.coordinator.attach(to: window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        if let window = nsView.window { context.coordinator.attach(to: window) }
    }

    final class Proxy: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool
        private weak var next: NSWindowDelegate?

        init(shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
        }

        /// Inserts self as the window's delegate, remembering the previous one
        /// to forward to. Idempotent.
        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            next = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            if let next, next.responds(to: #selector(windowShouldClose(_:))) {
                return next.windowShouldClose?(sender) ?? true
            }
            return true
        }

        // Forward every other delegate method to SwiftUI's original delegate.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (next?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            (next?.responds(to: aSelector) == true) ? next : nil
        }
    }
}
