import SwiftUI

/// Chooses what a window shows: the Welcome screen for an empty window, or a
/// full `WorkspaceView` once a folder or file has been opened. Also drains the
/// `LaunchRouter` queue so Finder / CLI opens become new windows.
struct WorkspaceRootView: View {
    let ref: WorkspaceRef?

    @Environment(\.openWindow) private var openWindow
    @State private var router = LaunchRouter.shared

    var body: some View {
        Group {
            if let ref {
                WorkspaceView(ref: ref)
            } else {
                WelcomeView()
            }
        }
        .onChange(of: router.pendingCount) { _, count in
            guard count > 0 else { return }
            for queued in router.drain() {
                openWindow(value: queued)
            }
        }
        .onAppear {
            // Register as a drain view and open anything that was queued before
            // this window's observer existed (`onChange` never fires for an
            // already-nonzero count).
            for queued in router.drainViewAppeared(opener: { openWindow(value: $0) }) {
                openWindow(value: queued)
            }
        }
        .onDisappear {
            router.drainViewDisappeared()
        }
    }
}
