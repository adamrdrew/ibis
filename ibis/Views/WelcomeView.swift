import SwiftUI
import AppKit

/// The empty-window landing screen. Offers quick ways to open a file or folder.
/// Recents and the CLI-install hint arrive in later phases.
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bird.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Ibis")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("A text editor for developers")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    openPanel(chooseDirectories: false)
                } label: {
                    Label("Open File…", systemImage: "doc")
                }
                Button {
                    openPanel(chooseDirectories: true)
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(60)
        .frame(minWidth: 560, minHeight: 460)
    }

    private func openPanel(chooseDirectories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !chooseDirectories
        panel.canChooseDirectories = chooseDirectories
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: WorkspaceRef(url: url, isDirectory: chooseDirectories))
    }
}
