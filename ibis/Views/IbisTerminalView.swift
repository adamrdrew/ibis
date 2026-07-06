import AppKit
import SwiftTerm

/// The terminal view Ibis instantiates: SwiftTerm's `LocalProcessTerminalView`
/// minus its per-keystroke debug chatter. SwiftTerm's `NSTextInputClient`
/// conformance `print`s "Attribuetd string" (sic) every time the text-input
/// system asks for an attributed substring — i.e. on every keystroke. Upstream
/// returns nil after printing; the method is `open`, so this override keeps the
/// behavior and drops the print.
final class IbisTerminalView: LocalProcessTerminalView {
    override func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }
}

/// Makes the mouse wheel scroll full-screen TUIs in the integrated terminal.
///
/// SwiftTerm's `scrollWheel` only ever moves its own native scrollback; it never
/// reports the wheel to the running program, even when that program has turned
/// on mouse tracking. Two kinds of full-screen app therefore can't be scrolled:
///
/// 1. **Mouse-tracking TUIs** (Claude Code's `/tui` *fullscreen* renderer, `htop`
///    with the mouse on, etc.). These paint a fixed-layout screen and manage
///    their own scroll region, expecting the terminal to send wheel motions as
///    mouse-button reports (SGR/X10 button 64/65). SwiftTerm swallows the wheel
///    instead, so nothing scrolls. We encode and send those reports ourselves —
///    exactly what Terminal.app and iTerm2 do. (Note: Claude's fullscreen mode
///    stays on the *normal* buffer, so this can't be gated on the alternate
///    buffer; it keys off `mouseMode`.)
///
/// 2. **Alternate-buffer pagers without mouse tracking** (`less`, `vim`, `man`).
///    The alternate screen has no scrollback, so there's nothing for SwiftTerm
///    to move. We translate the wheel into cursor up/down keys so the program
///    scrolls itself.
///
/// Everything else — a plain shell, or Claude Code's *default* renderer, both of
/// which use normal-buffer scrollback with no mouse tracking — is left to
/// SwiftTerm's own (working) handling. SwiftTerm marks `scrollWheel` `public`,
/// not `open`, so it can't be overridden in a subclass — hence a local monitor.
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

    /// Handles a wheel scroll over a terminal view. Returns whether it was consumed.
    private static func handle(_ event: NSEvent) -> Bool {
        guard event.deltaY != 0,
              let contentView = event.window?.contentView,
              let hit = contentView.hitTest(event.locationInWindow),
              let terminalView = enclosingTerminalView(hit) else { return false }

        let terminal = terminalView.getTerminal()

        // Scale to the scroll magnitude but stay modest, so a fast flick doesn't
        // fire dozens of events at once.
        let steps = min(max(1, Int(abs(event.deltaY))), 6)

        // 1. The program is tracking the mouse: report the wheel to it. This is
        //    the path Claude Code's fullscreen renderer needs.
        if terminal.mouseMode != .off && terminalView.allowMouseReporting {
            sendWheelReport(event, up: event.deltaY > 0, steps: steps, to: terminalView, terminal: terminal)
            return true
        }

        // 2. Alternate-buffer pager without mouse tracking: synthesize cursor keys.
        if terminal.isCurrentBufferAlternate {
            let sequence: [UInt8]
            if event.deltaY > 0 {
                sequence = terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
            } else {
                sequence = terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
            }
            for _ in 0..<steps { terminalView.send(sequence) }
            return true
        }

        // 3. Normal buffer, no mouse tracking (plain shell, Claude's default
        //    renderer): let SwiftTerm scroll its native scrollback.
        return false
    }

    /// Encodes wheel motion as a mouse-button report (button 4 = up, 5 = down) at
    /// the cell under the pointer and sends it to the running program. SwiftTerm
    /// picks the wire format (X10 / SGR / …) from the mode the program requested.
    private static func sendWheelReport(_ event: NSEvent, up: Bool, steps: Int,
                                        to terminalView: LocalProcessTerminalView, terminal: Terminal) {
        let flags = event.modifierFlags
        let buttonFlags = terminal.encodeButton(
            button: up ? 4 : 5,
            release: false,
            shift: flags.contains(.shift),
            meta: flags.contains(.option),
            control: flags.contains(.control))

        let (col, row) = cell(for: event, in: terminalView, terminal: terminal)
        for _ in 0..<steps {
            terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
        }
    }

    /// The terminal cell (0-based col/row, top-left origin) under the pointer.
    /// SwiftTerm's own hit-testing is private, so we derive it from the view
    /// geometry — precise enough for wheel reports, which most TUIs use only to
    /// pick a scroll target.
    private static func cell(for event: NSEvent, in terminalView: NSView, terminal: Terminal) -> (col: Int, row: Int) {
        let point = terminalView.convert(event.locationInWindow, from: nil)
        let width = terminalView.bounds.width
        let height = terminalView.bounds.height
        let cellW = width / CGFloat(max(terminal.cols, 1))
        let cellH = height / CGFloat(max(terminal.rows, 1))
        let col = min(max(0, Int(point.x / max(cellW, 1))), terminal.cols - 1)
        // AppKit's y grows upward; terminal rows grow downward from the top.
        let row = min(max(0, Int((height - point.y) / max(cellH, 1))), terminal.rows - 1)
        return (col, row)
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
