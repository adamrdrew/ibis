import SwiftUI

/// The slim bar across the bottom of a workspace window, showing live Git status
/// (branch, dirty state, ahead/behind) or a friendly note when there's no repo.
struct StatusBarView: View {
    let git: GitStatusModel

    var body: some View {
        HStack(spacing: 10) {
            gitSection
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    @ViewBuilder
    private var gitSection: some View {
        let info = git.info
        if info.isRepository {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(info.branch ?? info.shortHead ?? "detached")
            }
            .help(info.isDetached ? "Detached HEAD" : "Current branch")

            if info.isDirty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.ibisKelly)
                        .frame(width: 6, height: 6)
                    Text("Changes")
                }
                .help("Uncommitted changes")
            }

            if info.hasUpstream {
                if info.isSynced {
                    Label("Up to date", systemImage: "checkmark.circle")
                        .labelStyle(.iconOnly)
                        .help("In sync with upstream")
                } else {
                    HStack(spacing: 8) {
                        if info.ahead > 0 {
                            countBadge("arrow.up", info.ahead)
                                .help("\(info.ahead) commit(s) to push")
                        }
                        if info.behind > 0 {
                            countBadge("arrow.down", info.behind)
                                .help("\(info.behind) commit(s) to pull")
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("Not a Git repository")
            }
        }
    }

    private func countBadge(_ symbol: String, _ count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text("\(count)")
        }
    }
}
