import SwiftUI
import AppKit

/// Installs an `NSWindowDelegate` on the hosting window that can veto closing
/// (via `shouldClose`) — e.g. to confirm unsaved changes with a sheet. All other
/// delegate methods are forwarded to SwiftUI's own window delegate so scene
/// management keeps working.
///
/// `shouldClose` returns `true` to allow an immediate close. It may instead
/// return `false` and later invoke the supplied `proceed` closure once an async
/// decision (a save sheet) resolves; `proceed` re-issues the close, which the
/// guard then lets through.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: (_ proceed: @escaping () -> Void) -> Bool

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
        var shouldClose: (_ proceed: @escaping () -> Void) -> Bool
        private weak var next: NSWindowDelegate?
        /// Set once an async decision has approved the close, so the re-issued
        /// close passes straight through. Consumed by that one close attempt —
        /// left latched, it would silently skip the unsaved-changes prompt on
        /// every later ⌘W if the approved close was vetoed downstream.
        private var closeApproved = false

        init(shouldClose: @escaping (_ proceed: @escaping () -> Void) -> Bool) {
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
            if closeApproved {
                closeApproved = false
                return forwardShouldClose(sender)
            }
            let allow = shouldClose { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.closeApproved = true
                sender.performClose(nil)
            }
            guard allow else { return false }
            return forwardShouldClose(sender)
        }

        private func forwardShouldClose(_ sender: NSWindow) -> Bool {
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
