import SwiftUI

/// The diff review sheet shown when an agent proposes an edit (MCP
/// `propose_edit`). Presents a unified diff and lets the human apply or discard;
/// dismissing counts as discard.
struct DiffReviewView: View {
    let proposal: DiffProposal
    let onApply: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            diffBody
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
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

    private var diffBody: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(proposal.lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(gutter(for: line.kind))
                            .frame(width: 12, alignment: .center)
                            .foregroundStyle(.secondary)
                        Text(line.text.isEmpty ? " " : line.text)
                            .textSelection(.enabled)
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
        }
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
