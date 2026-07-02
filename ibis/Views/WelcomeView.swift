import SwiftUI
import AppKit

/// The empty-window landing screen. Offers quick ways to open a file or folder.
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow

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

            Text("Tip: run `ibis .` in Terminal to open the current folder.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(minWidth: 520, minHeight: 440)
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
