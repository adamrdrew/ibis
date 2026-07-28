import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A typed payload for dragging editor tabs. Using a dedicated content type
/// (rather than a bare `String`) means a tab dropped onto the code editor or the
/// terminal is *not* accepted as plain text — so a slightly-missed reorder can no
/// longer insert a UUID into the document or paste it into the shell.
private extension UTType {
    static let ibisEditorTab = UTType(exportedAs: "com.adamdrew.ibis.editor-tab")
}

private struct EditorTabTransfer: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ibisEditorTab)
    }
}

/// The horizontal tab strip at the top of an editor pane.
struct TabBarView: View {
    let workspace: Workspace
    @Bindable var pane: EditorPane
    var isPaneActive: Bool
    var onSelect: (OpenDocument) -> Void
    var onClose: (OpenDocument) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(pane.tabDocuments) { document in
                    TabItemView(
                        workspace: workspace,
                        pane: pane,
                        document: document,
                        isCurrent: pane.selectedID == document.id,
                        isPaneActive: isPaneActive,
                        onSelect: { onSelect(document) },
                        onClose: { onClose(document) }
                    )
                    .draggable(EditorTabTransfer(id: document.id))
                    .dropDestination(for: EditorTabTransfer.self) { items, _ in
                        guard let dropped = items.first else { return false }
                        // moveTab returns false for a tab from another pane, so the
                        // drop declines rather than animating an accepted no-op.
                        return pane.moveTab(fromID: dropped.id, toID: document.id)
                    }
                }
            }
        }
        // `.never` (not `.hidden`): on macOS 26 a `.hidden` horizontal indicator
        // can still surface a scroller when the tabs overflow; `.never` keeps the
        // strip scrollable with no bar on both 26 and 27.
        .scrollIndicators(.never)
    }
}

private struct TabItemView: View {
    let workspace: Workspace
    let pane: EditorPane
    let document: OpenDocument
    var isCurrent: Bool
    var isPaneActive: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @Environment(\.ibisAccent) private var accent
    @State private var isHovering = false

    var body: some View {
        // The *whole* tab is the select button — icon, name, and the padding
        // around them — so a click anywhere activates it. It used to wrap only
        // the icon+label, which left the padding and the close slot dead: clicks
        // landed a few points off the text and did nothing, and the tab read as
        // unresponsive. It stays a real Button (not a tap gesture) so it's
        // reachable by Full Keyboard Access and VoiceOver.
        Button(action: onSelect) {
            HStack(spacing: 6) {
                // Reserves the close/dirty control's slot on the leading edge
                // (the macOS convention) so the tab's width never changes as
                // that control appears on hover. The control itself is drawn by
                // the overlay below, on top of this button.
                Color.clear
                    .frame(width: TabMetrics.slot, height: TabMetrics.slot)

                Image(systemName: document.url.map { FileIconProvider.symbolName(forFileURL: $0) } ?? "doc")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Text(document.name)
                    .lineLimit(1)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(document.name + (document.isDirty ? ", edited" : ""))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        // The close control sits in an overlay rather than in the layout so its
        // hit box can be comfortably larger than the glyph without widening the
        // tab: the bare `Image` was clickable only on its own drawn pixels.
        .overlay(alignment: .leading) {
            leading
                .frame(width: TabMetrics.hit, height: TabMetrics.hit)
                .padding(.leading, TabMetrics.hitLeadingInset)
        }
        .background(isCurrent ? AnyShapeStyle(.selection.opacity(isPaneActive ? 0.30 : 0.18)) : AnyShapeStyle(.clear))
        .overlay(alignment: .bottom) {
            if isCurrent {
                Rectangle()
                    .fill(isPaneActive ? accent : Color.secondary)
                    .frame(height: 2)
            }
        }
        // Middle-click closes the tab (routed through the dirty-safe close path).
        .overlay { MiddleClickCatcher(onMiddleClick: onClose) }
        .onHover { isHovering = $0 }
        .help(document.url?.path(percentEncoded: false) ?? "Untitled")
        .contextMenu {
            Button("Close Tab", action: onClose)
            Button("Close Other Tabs") {
                workspace.requestCloseOtherTabs(keeping: document, in: pane)
            }
            .disabled(pane.tabDocuments.count < 2)
            Button("Close Tabs to the Right") {
                workspace.requestCloseTabs(after: document, in: pane)
            }
            .disabled(isLastTab)

            Divider()

            Button("Copy Path") {
                if let path = document.url?.path(percentEncoded: false) {
                    FileOperations.copyToPasteboard(path)
                }
            }
            .disabled(document.url == nil)
            Button("Reveal in Finder") {
                if let url = document.url { FileOperations.revealInFinder(url) }
            }
            .disabled(document.url == nil)
        }
    }

    private var isLastTab: Bool {
        pane.tabDocuments.last?.id == document.id
    }

    @ViewBuilder
    private var leading: some View {
        if document.isDirty && !isHovering {
            // Indicators, unlike the close button, must stay transparent to
            // clicks — they sit on top of the select button, and a hit-testable
            // dot would punch a dead spot back into the tab.
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)
                .allowsHitTesting(false)
        } else if isHovering || isCurrent {
            TabCloseButton(label: "Close Tab", action: onClose)
        } else {
            Color.clear
                .allowsHitTesting(false)
        }
    }
}

/// Shared geometry for both tab strips' leading close control.
enum TabMetrics {
    /// The width reserved in the tab's layout for the close/dirty control.
    static let slot: CGFloat = 14
    /// The control's actual click target, drawn in an overlay so growing it
    /// doesn't change the tab's size.
    static let hit: CGFloat = 22
    /// Leading inset that centers the `hit` box over the reserved `slot`,
    /// given the tab's 10pt horizontal padding.
    static let hitLeadingInset: CGFloat = 10 - (hit - slot) / 2
    /// Diameter of the hover ring around the ✕.
    static let ring: CGFloat = 16
}

/// The tab close control: an ✕ that draws a subtle ring while the pointer is
/// over it, so the (deliberately generous) click target is discoverable —
/// Safari's affordance. Both the ring and the hit area are laid out inside the
/// overlay slot the tab reserves for this control, so neither can resize the tab
/// or reflow its title.
struct TabCloseButton: View {
    var label: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: TabMetrics.ring, height: TabMetrics.ring)
                .background {
                    Circle()
                        .strokeBorder(.secondary.opacity(0.45), lineWidth: 1)
                        .opacity(isHovering ? 1 : 0)
                }
                // Expands past the ring to fill the slot, so clicks near the ✕
                // still close: the bare glyph was hit-testable only on its own
                // drawn pixels.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A transparent overlay that reports middle-clicks (button 2). SwiftUI has no
/// middle-click gesture, so we drop to AppKit. The view is transparent to every
/// event *except* middle mouse, so left-click selection and the close button
/// keep working.
private struct MiddleClickCatcher: NSViewRepresentable {
    var onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ view: MiddleClickView, context: Context) {
        view.onMiddleClick = onMiddleClick
    }

    final class MiddleClickView: NSView {
        var onMiddleClick: (() -> Void)?

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 {
                onMiddleClick?()
            } else {
                super.otherMouseUp(with: event)
            }
        }

        // Only intercept middle-mouse events; be transparent to everything else
        // so tap-to-select and the close button still receive their clicks.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return self
            default:
                return nil
            }
        }
    }
}
