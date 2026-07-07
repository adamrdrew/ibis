import Testing
import Foundation
@testable import ibis

/// The editor's custom horizontal splitter: the pure width math, plus the
/// model-side restore wiring that stages saved pane proportions. The live drag
/// gesture needs a running window and is verified in the app.
@MainActor
@Suite(.serialized) struct PaneSplitTests {
    @Test func fractionsAreEachPanesShareOfTotalWidth() {
        #expect(PaneWidths.fractions(widths: [30, 70]) == [0.3, 0.7])
        #expect(PaneWidths.fractions(widths: [100, 100, 200]) == [0.25, 0.25, 0.5])
    }

    @Test func fractionsAreEmptyForZeroWidth() {
        // Before the split has laid out, widths can be zero — no divide-by-zero,
        // and the caller falls back to an equal split.
        #expect(PaneWidths.fractions(widths: [0, 0]).isEmpty)
        #expect(PaneWidths.fractions(widths: []).isEmpty)
    }

    @Test func widthsUseFractionsWhenTheyMatchTheCount() {
        #expect(PaneWidths.widths(content: 200, count: 2, fractions: [0.25, 0.75]) == [50, 150])
    }

    @Test func widthsFallBackToEqualSplit() {
        // No fractions, a count mismatch, or a degenerate (zero-sum) set all fall
        // back to an even division so a pane never collapses to nothing.
        #expect(PaneWidths.widths(content: 300, count: 3, fractions: nil) == [100, 100, 100])
        #expect(PaneWidths.widths(content: 200, count: 2, fractions: [0.5]) == [100, 100])
        #expect(PaneWidths.widths(content: 200, count: 2, fractions: [0, 0]) == [100, 100])
    }

    @Test func restoreKeepsSavedFractionsWhenEveryPaneSurvives() async throws {
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

                // Both panes survived, so the splitter lays them out at the saved
                // proportions.
                #expect(workspace.layout.panes.count == 2)
                #expect(workspace.paneWidthFractions == [0.35, 0.65])
            }
        }
    }

    @Test func restoreDropsSavedFractionsWhenAPaneIsLost() async throws {
        try await TestSupport.withIsolatedDefaults {
            try await TestSupport.withTempDir { dir in
                // Two panes were saved, but one pane's only file is now missing,
                // so the restored layout collapses to a single pane — the saved
                // two-way split no longer applies.
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
                #expect(workspace.paneWidthFractions == nil)
            }
        }
    }
}
