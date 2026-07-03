import SwiftUI
import AppKit

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
                    .draggable(document.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dropped = items.first, let fromID = UUID(uuidString: dropped) else { return false }
                        pane.moveTab(fromID: fromID, toID: document.id)
                        return true
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
            Image(systemName: document.url.map { FileIconProvider.symbolName(forFileURL: $0) } ?? "doc")
                .foregroundStyle(.secondary)
                .font(.caption)

            Text(document.name)
                .lineLimit(1)
                .font(.callout)

            trailing
                .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isCurrent ? AnyShapeStyle(.selection.opacity(isPaneActive ? 0.30 : 0.18)) : AnyShapeStyle(.clear))
        .overlay(alignment: .bottom) {
            if isCurrent {
                Rectangle()
                    .fill(isPaneActive ? Color.ibisKelly : Color.secondary)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // Middle-click closes the tab (routed through the dirty-safe close path).
        .overlay { MiddleClickCatcher(onMiddleClick: onClose) }
        .onHover { isHovering = $0 }
        .help(document.url?.path(percentEncoded: false) ?? "Untitled")
        .accessibilityLabel(document.name + (document.isDirty ? ", edited" : ""))
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
    private var trailing: some View {
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
