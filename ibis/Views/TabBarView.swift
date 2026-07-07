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
        .scrollIndicators(.hidden)
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

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Close / dirty indicator lives on the leading edge (the macOS
            // convention) in a fixed-width slot that's always present, so the
            // tab's width never changes as the close control appears on hover.
            leading
                .frame(width: 14, height: 14)

            // The selectable region is a real Button so it's reachable by Full
            // Keyboard Access and activatable by VoiceOver (a bare tap gesture is
            // invisible to both). The close control stays a sibling button.
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: document.url.map { FileIconProvider.symbolName(forFileURL: $0) } ?? "doc")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Text(document.name)
                        .lineLimit(1)
                        .font(.callout)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(document.name + (document.isDirty ? ", edited" : ""))
            .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isCurrent ? AnyShapeStyle(.selection.opacity(isPaneActive ? 0.30 : 0.18)) : AnyShapeStyle(.clear))
        .overlay(alignment: .bottom) {
            if isCurrent {
                Rectangle()
                    .fill(isPaneActive ? Color.ibisAccent : Color.secondary)
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
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)
        } else if isHovering || isCurrent {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close Tab")
            .help("Close Tab")
        } else {
            // Empty placeholder keeps the slot's width reserved so idle tabs
            // are the same size as hovered/active ones.
            Color.clear
        }
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
