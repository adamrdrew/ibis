import Testing
import Foundation
import AppKit
@testable import ibis

/// Tests the terminal *models* (dock + session bookkeeping) without ever
/// building a terminal view, so no shell process is spawned.
@MainActor
@Suite struct TerminalDockTests {
    private func makeDock() -> TerminalDock {
        TerminalDock(workingDirectory: URL(filePath: "/tmp"))
    }

    @Test func newSessionAppendsAndSelects() {
        let dock = makeDock()
        let first = dock.newSession()
        let second = dock.newSession()
        #expect(dock.sessions.count == 2)
        #expect(dock.activeSessionID == second.id)
        #expect(dock.activeSession === second)
        #expect(first.role == .shell)
    }

    @Test func activeSessionFallsBackToFirst() {
        let dock = makeDock()
        let session = dock.newSession()
        dock.activeSessionID = UUID() // stale id
        #expect(dock.activeSession === session)
    }

    @Test func newSessionCarriesProjectEnvAndCommand() {
        let dock = makeDock()
        dock.projectEnv = ["KEY": "value"]
        let session = dock.newSession(command: "run-me", title: "Agent", role: .agent)
        #expect(session.extraEnvironment == ["KEY": "value"])
        #expect(session.title == "Agent")
        #expect(session.role == .agent)
    }

    @Test func closeSessionSelectsNeighborAndHidesWhenEmpty() {
        let dock = makeDock()
        let a = dock.newSession()
        let b = dock.newSession()
        let c = dock.newSession()
        dock.isVisible = true

        dock.activeSessionID = b.id
        dock.closeSession(b.id)
        // Selection lands on the tab that took b's slot (c).
        #expect(dock.activeSessionID == c.id)
        #expect(dock.sessions.count == 2)

        dock.closeSession(c.id)
        #expect(dock.activeSessionID == a.id)
        dock.closeSession(a.id)
        #expect(dock.sessions.isEmpty)
        #expect(dock.activeSessionID == nil)
        #expect(dock.isVisible == false)
    }

    @Test func closingAnUnselectedSessionKeepsSelection() {
        let dock = makeDock()
        let a = dock.newSession()
        let b = dock.newSession()
        dock.activeSessionID = b.id
        dock.closeSession(a.id)
        #expect(dock.activeSessionID == b.id)
    }

    @Test func closeUnknownSessionIsNoOp() {
        let dock = makeDock()
        _ = dock.newSession()
        dock.closeSession(UUID())
        #expect(dock.sessions.count == 1)
    }

    @Test func selectAdjacentWrapsAround() {
        let dock = makeDock()
        let a = dock.newSession()
        let b = dock.newSession()
        let c = dock.newSession() // active
        dock.selectAdjacent(offset: 1)
        #expect(dock.activeSessionID == a.id)
        dock.selectAdjacent(offset: -1)
        #expect(dock.activeSessionID == c.id)
        _ = b
    }

    @Test func showCreatesAFirstTerminalAndToggleHides() {
        let dock = makeDock()
        dock.show()
        #expect(dock.isVisible)
        #expect(dock.sessions.count == 1)

        dock.toggle()
        #expect(dock.isVisible == false)
        #expect(dock.sessions.count == 1) // sessions survive hiding

        dock.toggle()
        #expect(dock.isVisible)
        #expect(dock.sessions.count == 1) // reuses the existing session
    }

    @Test func runActionCreatesOneReusableRunTab() {
        let dock = makeDock()
        dock.runAction(name: "Build", command: "make build")
        #expect(dock.isActionRunning)
        #expect(dock.isVisible)
        let run = dock.runSession
        #expect(run != nil)
        #expect(run?.role == .run)
        #expect(dock.activeSessionID == run?.id)
        #expect(run?.title == "Build")

        // A second action while one is running is refused (no clobbering).
        dock.runAction(name: "Test", command: "make test")
        #expect(dock.runSession?.title == "Build")
        #expect(dock.sessions.count == 1)

        // After stopping, the same tab is reused for the next action.
        dock.stopAction()
        #expect(dock.isActionRunning == false)
        dock.runAction(name: "Test", command: "make test")
        #expect(dock.sessions.count == 1)
        #expect(dock.runSession?.title == "Test")
        dock.stopAction()
    }

    @Test func stopActionWithoutARunSessionIsSafe() {
        let dock = makeDock()
        dock.stopAction()
        #expect(dock.isActionRunning == false)
    }
}

@MainActor
@Suite struct TerminalSessionTests {
    @Test func defaultTitleIsTheWorkingDirectoryName() {
        let session = TerminalSession(workingDirectory: URL(filePath: "/tmp/myproj"))
        #expect(session.title == "myproj")
        #expect(session.isRunning == false)
        #expect(session.hasStarted == false)
        #expect(session.exitCode == nil)
    }

    @Test func explicitTitleWins() {
        let session = TerminalSession(
            workingDirectory: URL(filePath: "/tmp"), command: "claude", title: "Claude", role: .agent
        )
        #expect(session.title == "Claude")
    }

    @Test func runBeforeViewBuildJustRetargets() {
        let session = TerminalSession(workingDirectory: URL(filePath: "/tmp"), role: .run)
        session.run(command: "make", title: "Build", extraEnvironment: ["A": "1"])
        #expect(session.title == "Build")
        #expect(session.command == "make")
        #expect(session.extraEnvironment == ["A": "1"])
        // No view yet, so nothing started.
        #expect(session.isRunning == false)
        #expect(session.terminalView == nil)
    }

    @Test func terminateWithoutARunningShellIsNoOp() {
        let session = TerminalSession(workingDirectory: URL(filePath: "/tmp"))
        var exited = false
        session.onExit = { exited = true }
        session.terminate()
        #expect(session.isRunning == false)
        #expect(exited == false) // guard fired before onExit
    }

    @Test func restartWithoutAViewIsNoOp() {
        let session = TerminalSession(workingDirectory: URL(filePath: "/tmp"))
        session.restart(shellOverride: nil)
        #expect(session.isRunning == false)
        #expect(session.hasStarted == false)
    }
}

/// Full-lifecycle integration: builds the real SwiftTerm view and forks a real
/// shell (the app is unsandboxed; /bin/sh keeps profile noise out). Serialized
/// to avoid a pile of concurrent PTYs.
@MainActor
@Suite(.serialized) struct TerminalSessionLifecycleTests {
    @Test func commandSessionRunsAndReportsExit() async throws {
        let session = TerminalSession(
            workingDirectory: URL.temporaryDirectory,
            command: "exit 3",
            title: "Exiter",
            role: .run
        )
        var exitCallbacks = 0
        session.onExit = { exitCallbacks += 1 }

        let view = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            shellOverride: "/bin/sh"
        )
        // The same view is returned on later calls (identity is load-bearing
        // for scrollback survival).
        #expect(session.makeTerminalView(font: .monospacedSystemFont(ofSize: 12, weight: .regular), shellOverride: nil) === view)

        let exited = await TestSupport.waitUntil(timeout: 15) {
            session.hasStarted && !session.isRunning
        }
        #expect(exited, "expected the command to run and exit")
        // SwiftTerm's kqueue child-monitor path reports the *raw* wait(2)
        // status (3 << 8 == 768) while its swift-subprocess path reports the
        // decoded code (3). Accept both; either way it must be nonzero.
        #expect(session.exitCode == 3 || session.exitCode == 3 << 8)
        #expect(exitCallbacks == 1)

        // A second terminate on the dead session must not fire onExit again.
        session.terminate()
        #expect(exitCallbacks == 1)
    }

    @Test func interactiveShellStartsAndTerminates() async throws {
        let session = TerminalSession(workingDirectory: URL.temporaryDirectory)
        _ = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            shellOverride: "/bin/sh"
        )
        let started = await TestSupport.waitUntil(timeout: 15) { session.isRunning }
        #expect(started)

        var exited = false
        session.onExit = { exited = true }
        session.terminate()
        #expect(session.isRunning == false)
        #expect(session.exitCode == nil) // terminate settles synchronously, no code
        #expect(exited)
    }

    @Test func titleEscapeSequencesUpdateTheTabTitle() async throws {
        let session = TerminalSession(workingDirectory: URL.temporaryDirectory, title: "Original")
        let view = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            shellOverride: "/bin/sh"
        )
        session.setTerminalTitle(source: view, title: "  fancy title  ")
        #expect(session.title == "fancy title")
        // Blank titles are ignored rather than clearing the tab.
        session.setTerminalTitle(source: view, title: "   ")
        #expect(session.title == "fancy title")

        _ = await TestSupport.waitUntil(timeout: 15) { session.isRunning }
        session.terminate()
    }
}
