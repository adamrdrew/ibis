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
    /// Routed through the workspace rather than straight to `dock.closeSession`,
    /// so closing a tab that's running something can confirm first.
    var onClose: (TerminalSession.ID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(dock.sessions) { session in
                    TerminalTabItemView(
                        session: session,
                        isCurrent: dock.activeSessionID == session.id,
                        onSelect: { dock.activeSessionID = session.id },
                        onClose: { onClose(session.id) }
                    )
                    .draggable(TerminalTabTransfer(id: session.id))
                    .dropDestination(for: TerminalTabTransfer.self) { items, _ in
                        guard let dropped = items.first else { return false }
                        return dock.moveSession(fromID: dropped.id, toID: session.id)
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

private struct TerminalTabItemView: View {
    let session: TerminalSession
    var isCurrent: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @Environment(\.ibisAccent) private var accent
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editingText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        tabContent
            // The close control sits in an overlay rather than in the layout so
            // its hit box can be comfortably larger than the glyph without
            // widening the tab: the bare `Image` was clickable only on its own
            // drawn pixels.
            .overlay(alignment: .leading) {
                leading
                    .frame(width: TabMetrics.hit, height: TabMetrics.hit)
                    .padding(.leading, TabMetrics.hitLeadingInset)
            }
            .background(isCurrent ? AnyShapeStyle(.selection.opacity(0.30)) : AnyShapeStyle(.clear))
            .overlay(alignment: .bottom) {
                if isCurrent {
                    Rectangle()
                        .fill(accent)
                        .frame(height: 2)
                }
            }
            .onHover { isHovering = $0 }
            .contextMenu {
                Button("Rename", action: beginRename)
                if session.hasManualName {
                    Button("Clear Custom Name", action: session.clearManualName)
                }
                Divider()
                Button("Close", action: onClose)
            }
    }

    @ViewBuilder
    private var tabContent: some View {
        if isEditing {
            row {
                TextField("Name", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(minWidth: 60)
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .onChange(of: fieldFocused) { _, focused in
                        // Commit on blur (click elsewhere), matching Terminal.app.
                        if !focused && isEditing { commitRename() }
                    }
            }
        } else {
            // The *whole* tab is the select button — icon, title, and the padding
            // around them — so a click anywhere activates it, and it's reachable
            // by Full Keyboard Access and VoiceOver.
            Button(action: onSelect) {
                row {
                    Text(session.title)
                        .lineLimit(1)
                        .font(.callout)
                        .foregroundStyle(session.isRunning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Double-click still renames, but as a *simultaneous* gesture. It
            // used to be a count-2 `onTapGesture` stacked on a count-1 one,
            // which makes SwiftUI hold the single tap until the system
            // double-click interval elapses — that wait, not any terminal work,
            // was the ~1s pause before a clicked terminal tab came into focus.
            // Simultaneous recognition lets the button fire on the first
            // mouse-up while the second click still starts the rename.
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename() })
            .accessibilityLabel(session.title + (session.isRunning ? "" : ", exited"))
            .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        }
    }

    /// The tab's contents: the reserved close-control slot, the terminal icon,
    /// and whatever names the tab. The padding lives inside so that it, too, is
    /// part of the select button's hit area.
    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            // Reserves the close control's slot on the leading edge (macOS
            // convention) so tab widths never shift when it appears on hover;
            // the control itself is drawn by the overlay in `body`.
            Color.clear
                .frame(width: TabMetrics.slot, height: TabMetrics.slot)

            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .font(.caption)

            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func beginRename() {
        editingText = session.title
        isEditing = true
        fieldFocused = true
    }

    private func commitRename() {
        session.rename(to: editingText)
        isEditing = false
    }

    private func cancelRename() {
        isEditing = false
    }

    @ViewBuilder
    private var leading: some View {
        if isHovering || isCurrent {
            TabCloseButton(label: "Close Terminal", action: onClose)
        } else {
            // Transparent to clicks: it sits on top of the select button, and a
            // hit-testable placeholder would punch a dead spot into the tab.
            Color.clear
                .allowsHitTesting(false)
        }
    }
}
