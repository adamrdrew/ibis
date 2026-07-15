import SwiftUI

/// The diff review sheet shown when an agent proposes an edit (MCP
/// `propose_edit`). Presents a unified diff and lets the human apply or discard;
/// dismissing counts as discard.
struct DiffReviewView: View {
    let proposal: DiffProposal
    let onApply: () -> Void
    let onDiscard: () -> Void

    /// The diff viewport's width, so rows can pad their backgrounds out to at
    /// least the visible width when every line is shorter than the sheet.
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            diffBody
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity,
               minHeight: 440, idealHeight: 560, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.ibisAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Proposed edit")
                    .font(.headline)
                Text(proposal.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("+\(proposal.added)  −\(proposal.removed)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // Layout notes: a bidirectional ScrollView proposes nil width, under which
    // a *Lazy*VStack collapses its rows to minimum width — the diff rendered as
    // an unreadable one-word-wide column. A plain VStack + `fixedSize` sizes
    // the column to the widest line instead (rows never wrap; long lines
    // scroll), and `minWidth: viewportWidth` stretches the row backgrounds to
    // the sheet's edge when every line is shorter than the viewport.
    private var diffBody: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(proposal.lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(gutter(for: line.kind))
                            .frame(width: 12, alignment: .center)
                            .foregroundStyle(.secondary)
                        Text(line.text.isEmpty ? " " : line.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: line.kind))
                }
            }
            .padding(.vertical, 6)
            .frame(minWidth: viewportWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { viewportWidth = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Text("Applying writes the file and saves it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Discard", role: .cancel, action: onDiscard)
                .keyboardShortcut(.cancelAction)
            Button("Apply", action: onApply)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.ibisAccent)
        }
        .padding(12)
    }

    private func gutter(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Color.green.opacity(0.16)
        case .removed: Color.red.opacity(0.16)
        case .context: Color.clear
        }
    }
}

#Preview("Diff review") {
    let old = """
    import SwiftUI

    struct StatusBadge: View {
        let title: String

        var body: some View {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 6)
                .background(Capsule().fill(Color.gray.opacity(0.2)))
        }
    }
    """
    let new = """
    import SwiftUI

    struct StatusBadge: View {
        let title: String
        let tint: Color

        var body: some View {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .background(Capsule().fill(tint.opacity(0.2)), alignment: .center) // a deliberately long line to exercise horizontal scrolling in the review sheet
        }
    }
    """
    DiffReviewView(
        proposal: DiffProposal(
            fileURL: URL(fileURLWithPath: "/tmp/StatusBadge.swift"),
            displayName: "Views/StatusBadge.swift",
            lines: LineDiff.compute(old: old, new: new),
            afterText: new,
            added: 3,
            removed: 2
        ),
        onApply: {},
        onDiscard: {}
    )
}
