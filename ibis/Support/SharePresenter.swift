import AppKit

/// Presents an `NSSharingServicePicker` and keeps it alive for the duration of
/// the presentation (a picker that deallocates immediately dismisses its
/// popover). Shared so both the menu bar and context menus can use it.
@MainActor
final class SharePresenter: NSObject, NSSharingServicePickerDelegate {
    static let shared = SharePresenter()

    private var picker: NSSharingServicePicker?

    func share(_ items: [Any], relativeTo rect: NSRect, of view: NSView) {
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        self.picker = nil
    }
}
