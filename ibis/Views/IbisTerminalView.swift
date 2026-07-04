import AppKit
import SwiftTerm

/// Makes the mouse wheel scroll full-screen TUIs in the integrated terminal.
///
/// SwiftTerm's `scrollWheel` only moves the native scrollback — but the
/// alternate screen buffer has no scrollback, so scrolling does nothing inside
/// pagers and TUIs like `less`, `vim`, `htop`, and Claude Code. Matching
/// Terminal.app and iTerm2, we translate wheel scrolls over an alternate-buffer
/// terminal into cursor up/down key presses so the running program scrolls
/// itself. (SwiftTerm marks `scrollWheel` `public`, not `open`, so it can't be
/// overridden in a subclass — hence a local event monitor.)
///
/// The normal buffer, and apps that turn on mouse reporting, are left untouched:
/// the event passes through to SwiftTerm's own handling.
@MainActor
enum TerminalScrollFix {
    /// Retains the installed monitor for the app's lifetime.
    private static var monitor: Any?

    /// Installs the scroll monitor once. Safe to call repeatedly.
    static func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Local monitors are delivered on the main thread.
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    /// Translates a wheel scroll over an alternate-buffer terminal into cursor
    /// keys. Returns whether the event was consumed.
    private static func handle(_ event: NSEvent) -> Bool {
        guard event.deltaY != 0,
              let contentView = event.window?.contentView,
              let hit = contentView.hitTest(event.locationInWindow),
              let terminalView = enclosingTerminalView(hit) else { return false }

        let terminal = terminalView.getTerminal()
        // Only when a full-screen app owns the alternate buffer and isn't itself
        // asking for mouse events.
        guard terminal.isCurrentBufferAlternate, terminal.mouseMode == .off else { return false }

        let up = event.deltaY > 0
        let sequence: [UInt8]
        if up {
            sequence = terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        } else {
            sequence = terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        }

        // Scale to the scroll magnitude but stay modest, so a fast flick doesn't
        // fire dozens of keypresses at once.
        let lines = min(max(1, Int(abs(event.deltaY))), 6)
        for _ in 0..<lines { terminalView.send(sequence) }
        return true
    }

    /// Walks up from a hit view to the enclosing terminal view, if any.
    private static func enclosingTerminalView(_ view: NSView) -> LocalProcessTerminalView? {
        var current: NSView? = view
        while let node = current {
            if let terminalView = node as? LocalProcessTerminalView { return terminalView }
            current = node.superview
        }
        return nil
    }
}
