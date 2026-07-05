import Testing
import Foundation
import AppKit
@testable import ibis

/// The AppKit split-view bridge that persists/restores editor pane widths. Its
/// attach-and-observe wiring needs a live window and can only be verified in the
/// running app; these cover the parts that are unit-testable: the width→fraction
/// math and the model-side restore wiring.
@MainActor
@Suite(.serialized) struct PaneLayoutBridgeTests {
    @Test func fractionsAreEachPanesShareOfTotalWidth() {
        #expect(PaneLayoutBridge.BridgeView.fractions(widths: [30, 70]) == [0.3, 0.7])
        #expect(PaneLayoutBridge.BridgeView.fractions(widths: [100, 100, 200]) == [0.25, 0.25, 0.5])
    }

    @Test func fractionsAreEmptyForZeroWidth() {
        // Before the split has laid out, widths can be zero — no divide-by-zero,
        // and the caller's count check then rejects the empty result.
        #expect(PaneLayoutBridge.BridgeView.fractions(widths: [0, 0]).isEmpty)
        #expect(PaneLayoutBridge.BridgeView.fractions(widths: []).isEmpty)
    }

    @Test func restoreArmsPendingFractionsWhenEveryPaneSurvives() async throws {
        try await TestSupport.withIsolatedDefaults {
            try await TestSupport.withTempDir { dir in
                let a = dir.appending(path: "a.txt")
                let b = dir.appending(path: "b.txt")
                try "a".write(to: a, atomically: true, encoding: .utf8)
                try "b".write(to: b, atomically: true, encoding: .utf8)
                var state = PersistedWorkspaceState(
                    paneFilePaths: [[a.path(percentEncoded: false)], [b.path(percentEncoded: false)]],
                    selectedTabPerPane: [0, 0],
                    activePaneIndex: 0,
                    savedAt: Date()
                )
                state.paneWidthFractions = [0.35, 0.65]
                WorkspaceStateStore.save(state, for: dir)

                let workspace = Workspace(rootURL: dir, isDirectory: true)
                await workspace.restorePersistedLayout()

                // Both panes survived, so the saved widths are staged for the
                // bridge to apply once the split view grows its panes.
                #expect(workspace.layout.panes.count == 2)
                #expect(workspace.paneWidthFractions == [0.35, 0.65])
                #expect(workspace.pendingPaneWidthFractions == [0.35, 0.65])
            }
        }
    }

    @Test func restoreDropsSavedFractionsWhenAPaneIsLost() async throws {
        try await TestSupport.withIsolatedDefaults {
            try await TestSupport.withTempDir { dir in
                // Two panes were saved, but one pane's only file is now missing,
                // so the restored layout collapses to a single pane — the saved
                // two-way split no longer applies and must not be staged.
                let survivor = dir.appending(path: "survivor.txt")
                try "s".write(to: survivor, atomically: true, encoding: .utf8)
                let gone = dir.appending(path: "gone.txt").path(percentEncoded: false)
                var state = PersistedWorkspaceState(
                    paneFilePaths: [[survivor.path(percentEncoded: false)], [gone]],
                    selectedTabPerPane: [0, 0],
                    activePaneIndex: 0,
                    savedAt: Date()
                )
                state.paneWidthFractions = [0.35, 0.65]
                WorkspaceStateStore.save(state, for: dir)

                let workspace = Workspace(rootURL: dir, isDirectory: true)
                await workspace.restorePersistedLayout()

                #expect(workspace.layout.panes.count == 1)
                #expect(workspace.pendingPaneWidthFractions == nil)
            }
        }
    }
}
