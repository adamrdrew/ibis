import SwiftUI

/// The horizontal tab strip at the top of an editor pane.
struct TabBarView: View {
    @Bindable var pane: EditorPane
    var isPaneActive: Bool
    var onSelect: (OpenDocument) -> Void
    var onClose: (OpenDocument) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(pane.tabDocuments) { document in
                    TabItemView(
                        document: document,
                        isCurrent: pane.selectedID == document.id,
                        isPaneActive: isPaneActive,
                        onSelect: { onSelect(document) },
                        onClose: { onClose(document) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct TabItemView: View {
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
        .onHover { isHovering = $0 }
        .help(document.url?.path(percentEncoded: false) ?? "Untitled")
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
        }
    }
}
