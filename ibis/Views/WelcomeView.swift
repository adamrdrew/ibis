import SwiftUI
import AppKit

/// The empty-window landing screen. Offers quick ways to open a file or folder,
/// a list of recent projects, and accepts folders dropped from Finder.
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var router = LaunchRouter.shared

    /// Recent projects, most-recent first, existing on disk, capped for the
    /// compact launcher. Recomputed each time the view appears.
    private var recents: [URL] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 66))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)

                VStack(spacing: 4) {
                    Text("Ibis")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("A text editor for developers")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                Button {
                    openPanel(chooseDirectories: true)
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    openPanel(chooseDirectories: false)
                } label: {
                    Label("Open File…", systemImage: "doc")
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            if recents.isEmpty {
                Text("Tip: run `ibis .` in Terminal to open the current folder.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                recentsList
            }
        }
        .padding(44)
        .frame(width: 460)
        // Open a folder or file dragged from Finder onto the launcher.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            open(url)
            return true
        }
        // Finder / CLI opens that arrive at launch: turn them into editor
        // windows and close the launcher. Registering as a drain view also lets
        // the router open windows itself when every window is closed later.
        .onAppear {
            _ = router.drainViewAppeared(opener: { openWindow(value: $0) })
            drainPendingOpens()
        }
        .onDisappear {
            router.drainViewDisappeared()
        }
        .onChange(of: router.pendingCount) { _, count in
            if count > 0 { drainPendingOpens() }
        }
    }

    // MARK: - Recents

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 2) {
                ForEach(recents, id: \.self) { url in
                    RecentRow(url: url) { open(url) }
                }
            }
        }
        .frame(width: 372, alignment: .leading)
    }

    // MARK: - Opening

    private func openPanel(chooseDirectories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !chooseDirectories
        panel.canChooseDirectories = chooseDirectories
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: WorkspaceRef(url: url, isDirectory: chooseDirectories))
        dismiss()
    }

    /// Opens a URL (determining folder vs file) and dismisses the launcher.
    private func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        openWindow(value: WorkspaceRef(url: url, isDirectory: isDirectory.boolValue))
        dismiss()
    }

    private func drainPendingOpens() {
        let pending = router.drain()
        guard !pending.isEmpty else { return }
        for ref in pending { openWindow(value: ref) }
        dismiss()
    }
}

/// A single recent-project row: the file/folder icon, its name, and the
/// abbreviated enclosing path.
private struct RecentRow: View {
    let url: URL
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent)
                        .font(.body)
                        .lineLimit(1)
                    Text(abbreviatedParent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(url.lastPathComponent), \(abbreviatedParent)")
    }

    private var abbreviatedParent: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
