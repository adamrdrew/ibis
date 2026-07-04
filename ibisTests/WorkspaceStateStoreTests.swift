import Testing
import Foundation
@testable import ibis

// Serialized: these tests share the process-wide UserDefaults key, and Swift
// Testing runs tests in parallel by default.
@Suite(.serialized) struct WorkspaceStateStoreTests {
    // Matches the private `key` in WorkspaceStateStore; snapshotting it keeps the
    // developer's standard defaults clean.
    private static let defaultsKey = "workspaceState.v1"

    private func sampleState() -> PersistedWorkspaceState {
        PersistedWorkspaceState(
            paneFilePaths: [["/a/one.swift", "/a/two.swift"], ["/a/three.swift"]],
            selectedTabPerPane: [1, 0],
            activePaneIndex: 0,
            savedAt: Date()
        )
    }

    @Test func savedStateRoundTrips() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let root = URL(filePath: "/tmp/proj-\(UUID().uuidString)")
            let state = sampleState()
            WorkspaceStateStore.save(state, for: root)

            let loaded = WorkspaceStateStore.load(for: root)
            #expect(loaded?.paneFilePaths == state.paneFilePaths)
            #expect(loaded?.selectedTabPerPane == state.selectedTabPerPane)
            #expect(loaded?.activePaneIndex == state.activePaneIndex)
        }
    }

    @Test func loadForUnknownRootReturnsNil() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            #expect(WorkspaceStateStore.load(for: URL(filePath: "/never/saved-\(UUID().uuidString)")) == nil)
        }
    }

    @Test func distinctRootsStoreSeparateState() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let a = URL(filePath: "/tmp/a-\(UUID().uuidString)")
            let b = URL(filePath: "/tmp/b-\(UUID().uuidString)")
            var stateA = sampleState(); stateA.activePaneIndex = 0
            var stateB = sampleState(); stateB.activePaneIndex = 1
            WorkspaceStateStore.save(stateA, for: a)
            WorkspaceStateStore.save(stateB, for: b)
            #expect(WorkspaceStateStore.load(for: a)?.activePaneIndex == 0)
            #expect(WorkspaceStateStore.load(for: b)?.activePaneIndex == 1)
        }
    }

    @Test func evictsOldestRootsBeyondCap() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            // Save 25 roots (cap is 20); the earliest-dated should be evicted.
            let base = Date(timeIntervalSince1970: 1_000_000)
            var roots: [URL] = []
            for index in 0..<25 {
                let root = URL(filePath: "/tmp/cap-\(index)")
                roots.append(root)
                var state = sampleState()
                state.savedAt = base.addingTimeInterval(TimeInterval(index)) // older first
                WorkspaceStateStore.save(state, for: root)
            }
            // The 5 oldest are gone; the newest remains.
            #expect(WorkspaceStateStore.load(for: roots[0]) == nil)
            #expect(WorkspaceStateStore.load(for: roots[24]) != nil)
        }
    }
}
