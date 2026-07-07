import SwiftUI
import UniformTypeIdentifiers

/// A typed payload for dragging terminal tabs. Like the editor's tab transfer, a
/// dedicated content type (not a bare `String`) means a tab dropped onto the
/// terminal view is *not* accepted as plain text — so a slightly-missed reorder
/// can no longer paste a UUID into the running shell.
private extension UTType {
    static let ibisTerminalTab = UTType(exportedAs: "com.adamdrew.ibis.terminal-tab")
}

private struct TerminalTabTransfer: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ibisTerminalTab)
    }
}

/// The horizontal tab strip in the terminal dock header. Parallels the editor's
/// `TabBarView`: click to activate, kelly underline on the active tab.
struct TerminalTabBarView: View {
    @Bindable var dock: TerminalDock

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(dock.sessions) { session in
                    TerminalTabItemView(
                        session: session,
                        isCurrent: dock.activeSessionID == session.id,
                        onSelect: { dock.activeSessionID = session.id },
                        onClose: { dock.closeSession(session.id) }
                    )
                    .draggable(TerminalTabTransfer(id: session.id))
                    .dropDestination(for: TerminalTabTransfer.self) { items, _ in
                        guard let dropped = items.first else { return false }
                        return dock.moveSession(fromID: dropped.id, toID: session.id)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct TerminalTabItemView: View {
    let session: TerminalSession
    var isCurrent: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Close control on the leading edge (macOS convention) in a
            // fixed-width slot that's always present, so tab widths never shift
            // when the close button appears on hover.
            leading
                .frame(width: 14, height: 14)

            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Text(session.title)
                        .lineLimit(1)
                        .font(.callout)
                        .foregroundStyle(session.isRunning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.title + (session.isRunning ? "" : ", exited"))
            .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isCurrent ? AnyShapeStyle(.selection.opacity(0.30)) : AnyShapeStyle(.clear))
        .overlay(alignment: .bottom) {
            if isCurrent {
                Rectangle()
                    .fill(Color.ibisAccent)
                    .frame(height: 2)
            }
        }
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var leading: some View {
        if isHovering || isCurrent {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close Terminal")
            .help("Close Terminal")
        } else {
            // Empty placeholder keeps the slot's width reserved so idle tabs
            // match hovered/active ones.
            Color.clear
        }
    }
}
