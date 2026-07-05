import Testing
import Foundation
@testable import ibis

// @MainActor so the test closures inherit the isolation the store requires;
// each test runs against its own throwaway defaults suite (withIsolatedDefaults).
@MainActor
@Suite(.serialized) struct WorkspaceStateStoreTests {
    // Matches the private `key` in WorkspaceStateStore; used only by the
    // legacy-migration test, which pokes the isolated suite's raw dictionary.
    private static let defaultsKey = "workspaceState.v1"

    private func sampleState() -> PersistedWorkspaceState {
        PersistedWorkspaceState(
            paneFilePaths: [["/a/one.swift", "/a/two.swift"], ["/a/three.swift"]],
            selectedTabPerPane: [1, 0],
            activePaneIndex: 0,
            savedAt: Date()
        )
    }

    @Test func savedStateRoundTrips() async {
        await TestSupport.withIsolatedDefaults {
            let root = URL(filePath: "/tmp/proj-\(UUID().uuidString)")
            let state = sampleState()
            WorkspaceStateStore.save(state, for: root)

            let loaded = WorkspaceStateStore.load(for: root)
            #expect(loaded?.paneFilePaths == state.paneFilePaths)
            #expect(loaded?.selectedTabPerPane == state.selectedTabPerPane)
            #expect(loaded?.activePaneIndex == state.activePaneIndex)
        }
    }

    @Test func terminalDockRoundTrips() async {
        await TestSupport.withIsolatedDefaults {
            let root = URL(filePath: "/tmp/proj-\(UUID().uuidString)")
            let sid = UUID().uuidString
            var state = sampleState()
            state.terminal = PersistedTerminalDock(
                sessions: [
                    PersistedTerminalSession(role: .shell, title: "zsh", agentSessionID: nil),
                    PersistedTerminalSession(role: .agent, title: "Claude", agentSessionID: sid)
                ],
                activeSessionIndex: 1,
                isVisible: true
            )
            WorkspaceStateStore.save(state, for: root)

            let loaded = WorkspaceStateStore.load(for: root)?.terminal
            #expect(loaded?.sessions.count == 2)
            #expect(loaded?.sessions[0].role == .shell)
            #expect(loaded?.sessions[1].role == .agent)
            #expect(loaded?.sessions[1].agentSessionID == sid)
            #expect(loaded?.activeSessionIndex == 1)
            #expect(loaded?.isVisible == true)
        }
    }

    @Test func roleEncodesAsPlainStrings() async throws {
        // The wire format predates the typed role ("shell"/"agent" strings);
        // payloads written by either version must decode in the other.
        let session = PersistedTerminalSession(role: .agent, title: "Claude", agentSessionID: nil)
        let json = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(json.contains("\"agent\""))

        let legacy = Data(#"{"role": "shell", "title": "zsh"}"#.utf8)
        let decoded = try JSONDecoder().decode(PersistedTerminalSession.self, from: legacy)
        #expect(decoded.role == .shell)
    }

    @Test func paneWidthFractionsRoundTripAndDefaultToNil() async {
        await TestSupport.withIsolatedDefaults {
            let root = URL(filePath: "/tmp/proj-\(UUID().uuidString)")
            var state = sampleState()
            state.paneWidthFractions = [0.3, 0.7]
            WorkspaceStateStore.save(state, for: root)
            #expect(WorkspaceStateStore.load(for: root)?.paneWidthFractions == [0.3, 0.7])

            // Older payloads without the key decode with nil fractions.
            let legacyRoot = URL(filePath: "/tmp/proj-\(UUID().uuidString)")
            WorkspaceStateStore.save(sampleState(), for: legacyRoot)
            #expect(WorkspaceStateStore.load(for: legacyRoot)?.paneWidthFractions == nil)
        }
    }

    @Test func legacyStateWithoutTerminalDecodes() async {
        await TestSupport.withIsolatedDefaults {
            // A payload written before terminal persistence has no `terminal` key;
            // it must still decode, with `terminal == nil`.
            let root = URL(filePath: "/tmp/proj-\(UUID().uuidString)")
            var state = sampleState()
            state.terminal = nil
            WorkspaceStateStore.save(state, for: root)

            let loaded = WorkspaceStateStore.load(for: root)
            #expect(loaded != nil)
            #expect(loaded?.terminal == nil)
        }
    }

    @Test func trailingSlashKeysCollapse() async {
        await TestSupport.withIsolatedDefaults {
            // Finder/`open` open a folder with a trailing slash, the CLI usually
            // without — both must map to one entry so a layout saved under one
            // spelling restores under the other.
            let unique = "/tmp/proj-\(UUID().uuidString)"
            WorkspaceStateStore.save(sampleState(), for: URL(filePath: unique + "/"))
            #expect(WorkspaceStateStore.load(for: URL(filePath: unique)) != nil)

            // …and the reverse: save bare, load with a trailing slash.
            let other = "/tmp/proj-\(UUID().uuidString)"
            WorkspaceStateStore.save(sampleState(), for: URL(filePath: other))
            #expect(WorkspaceStateStore.load(for: URL(filePath: other + "/")) != nil)
        }
    }

    @Test func legacyTrailingSlashEntryLoadsAndMigratesOnSave() async throws {
        try await TestSupport.withIsolatedDefaults {
            // Entries written before key normalization were keyed exactly as
            // the URL was spelled — with a trailing slash for Finder-opened
            // folders. They must still load, and a save must migrate them so
            // they don't linger as orphans against the eviction cap.
            let path = "/tmp/proj-\(UUID().uuidString)"
            let encoded = try JSONEncoder().encode(sampleState())
            IbisDefaults.store.set([path + "/": encoded], forKey: Self.defaultsKey)

            #expect(WorkspaceStateStore.load(for: URL(filePath: path)) != nil)

            WorkspaceStateStore.save(sampleState(), for: URL(filePath: path))
            let dict = IbisDefaults.store.dictionary(forKey: Self.defaultsKey) ?? [:]
            #expect(dict[path] != nil)
            #expect(dict[path + "/"] == nil)
        }
    }

    @Test func loadForUnknownRootReturnsNil() async {
        await TestSupport.withIsolatedDefaults {
            #expect(WorkspaceStateStore.load(for: URL(filePath: "/never/saved-\(UUID().uuidString)")) == nil)
        }
    }

    @Test func distinctRootsStoreSeparateState() async {
        await TestSupport.withIsolatedDefaults {
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

    @Test func evictsOldestRootsBeyondCap() async {
        await TestSupport.withIsolatedDefaults {
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
