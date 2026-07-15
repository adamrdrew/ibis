import Testing
import Foundation
import AppKit
@testable import Ibis

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

    @Test func extraLaunchEnvironmentMergesOverProjectEnv() {
        let dock = makeDock()
        dock.projectEnv = ["SHARED": "project", "PROJECT_ONLY": "1"]
        dock.extraLaunchEnvironment = ["SHARED": "adhoc", "IBIS_MCP_TOKEN": "tok"]
        #expect(dock.launchEnvironment == [
            "SHARED": "adhoc", "PROJECT_ONLY": "1", "IBIS_MCP_TOKEN": "tok",
        ])

        // New sessions and the reusable Run tab both get the merged env.
        let session = dock.newSession()
        #expect(session.extraEnvironment == dock.launchEnvironment)
        dock.runAction(name: "Build", command: "make build")
        #expect(dock.runSession?.extraEnvironment == dock.launchEnvironment)
        dock.stopAction()
    }

    @Test func runActionUsesTheCurrentShellOverride() {
        let dock = makeDock()
        var configuredShell: String? = "/bin/zsh"
        dock.shellOverrideProvider = { configuredShell }

        dock.runAction(name: "Build", command: "make build")
        #expect(dock.runSession?.lastShellOverride == "/bin/zsh")
        dock.stopAction()

        // The user changes the shell path in Settings; a re-run must pick up
        // the new value, not the one frozen at the first launch.
        configuredShell = "/bin/fish"
        dock.runAction(name: "Build", command: "make build")
        #expect(dock.runSession?.lastShellOverride == "/bin/fish")
        dock.stopAction()

        // Clearing the setting means "no override" (default shell resolution).
        configuredShell = nil
        dock.runAction(name: "Build", command: "make build")
        #expect(dock.runSession?.lastShellOverride == nil)
        dock.stopAction()
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
        session.run(command: "make", title: "Build", extraEnvironment: ["A": "1"], shellOverride: "/bin/fish")
        #expect(session.title == "Build")
        #expect(session.command == "make")
        #expect(session.extraEnvironment == ["A": "1"])
        // The override is recorded even before the view exists, so the later
        // start (and `relaunch`) uses the settings value current at run time.
        #expect(session.lastShellOverride == "/bin/fish")
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
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        )
        // The same view is returned on later calls (identity is load-bearing
        // for scrollback survival).
        #expect(session.makeTerminalView(font: .monospacedSystemFont(ofSize: 12, weight: .regular), theme: TerminalThemeCatalog.fallbackDark, shellOverride: nil) === view)

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

    @Test func processExitReportsCodeAndDurationForAQuickFailure() async throws {
        // Mimics `claude --resume <missing>` failing fast: window restore relies on
        // onProcessExit reporting a nonzero code and a short duration to recover.
        let session = TerminalSession(
            workingDirectory: URL.temporaryDirectory,
            command: "exit 1",
            title: "Claude",
            role: .agent
        )
        var reportedCode: Int32?
        var reportedRanFor = TimeInterval.infinity
        var fired = false
        session.onProcessExit = { code, ranFor in
            reportedCode = code; reportedRanFor = ranFor; fired = true
        }
        _ = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        )
        let exited = await TestSupport.waitUntil(timeout: 15) { fired }
        #expect(exited, "expected onProcessExit to fire on exit")
        #expect((reportedCode ?? 0) != 0) // nonzero → the resume failed
        #expect(reportedRanFor < 15)      // and it failed quickly
    }

    @Test func relaunchCanReplaceTheCommand() async throws {
        // A Claude tab whose conversation is gone for good relaunches re-pinned
        // with `--session-id` instead of the failed `--resume` — so relaunch
        // must accept a replacement command.
        let session = TerminalSession(
            workingDirectory: URL.temporaryDirectory,
            command: "exit 1",
            title: "Claude",
            role: .agent
        )
        _ = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        )
        _ = await TestSupport.waitUntil(timeout: 15) { session.hasStarted && !session.isRunning }

        session.relaunch(notice: "starting the conversation over", command: "sleep 30")
        #expect(session.command == "sleep 30")
        let running = await TestSupport.waitUntil(timeout: 15) { session.isRunning }
        #expect(running, "relaunch should start the fresh command in the same view")
        session.terminate()
    }

    @Test func restartCanReplaceTheCommand() async throws {
        // An exited Claude agent tab restarts via `--resume <sid>` — re-running
        // the original `--session-id` launch is rejected ("already in use") once
        // the session exists — so restart must accept a replacement command.
        let session = TerminalSession(
            workingDirectory: URL.temporaryDirectory,
            command: "exit 1",
            title: "Claude",
            role: .agent
        )
        _ = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        )
        _ = await TestSupport.waitUntil(timeout: 15) { session.hasStarted && !session.isRunning }

        session.restart(shellOverride: "/bin/sh", command: "sleep 30")
        #expect(session.command == "sleep 30")
        let running = await TestSupport.waitUntil(timeout: 15) { session.isRunning }
        #expect(running, "restart should start the replacement command in the same view")
        session.terminate()
    }

    @Test func relaunchWithoutArgumentsRetriesTheSameCommand() async throws {
        // A resume rejected because the previous window's agent was still
        // closing ("already in use") is retried verbatim in the same tab.
        let session = TerminalSession(
            workingDirectory: URL.temporaryDirectory,
            command: "exit 7",
            title: "Claude",
            role: .agent
        )
        var exits = 0
        session.onProcessExit = { _, _ in exits += 1 }
        _ = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        )
        _ = await TestSupport.waitUntil(timeout: 15) { exits == 1 }

        session.relaunch(notice: "retrying")
        #expect(session.command == "exit 7") // unchanged — same resume command
        let reran = await TestSupport.waitUntil(timeout: 15) { exits == 2 }
        #expect(reran, "relaunch should run the command again in the same view")
    }

    @Test func commandTabTitleIsNotClobberedByTheComputedTitle() async throws {
        // A Run-action tab is named by its action ("Build") or its own escape
        // titles — the computed cwd/shell title must never overwrite it (make/
        // npm emit no OSC titles, so the wrong title would stick forever).
        let session = TerminalSession(
            workingDirectory: URL.temporaryDirectory,
            command: "sleep 30",
            title: "Build",
            role: .run
        )
        _ = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        )
        let started = await TestSupport.waitUntil(timeout: 15) { session.isRunning }
        #expect(started)
        #expect(session.title == "Build")

        // A title-mode change must not seed a computed title for it either.
        session.apply(titleMode: .activeProcess)
        #expect(session.title == "Build")
        session.terminate()
        #expect(session.title == "Build")
    }

    @Test func interactiveShellStartsAndTerminates() async throws {
        let session = TerminalSession(workingDirectory: URL.temporaryDirectory)
        _ = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
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

    @Test func exitedShellArmsTheReturnKeyRestartHook() async throws {
        let session = TerminalSession(
            workingDirectory: URL.temporaryDirectory,
            command: "exit 0",
            title: "Claude",
            role: .agent
        )
        var restartRequests = 0
        session.onRestartRequest = { restartRequests += 1; return true }
        let view = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        ) as? IbisTerminalView
        #expect(view != nil)

        let exited = await TestSupport.waitUntil(timeout: 15) {
            session.hasStarted && !session.isRunning
        }
        #expect(exited)
        // Dead shell → plain Return in the terminal is intercepted and routed
        // to the restart request (the focus-scoped replacement for the old
        // window-global .keyboardShortcut(.return), which hijacked the editor).
        #expect(view?.returnKeyAction != nil)
        #expect(view?.returnKeyAction?() == true)
        #expect(restartRequests == 1)

        // Restarting disarms the hook while the process is alive again.
        session.restart(shellOverride: "/bin/sh", command: "sleep 30")
        let running = await TestSupport.waitUntil(timeout: 15) { session.isRunning }
        #expect(running)
        #expect(view?.returnKeyAction == nil)
        session.terminate()
    }

    @Test func runTabsNeverArmTheReturnKeyRestartHook() async throws {
        // Action tabs have no "Shell exited — Restart" affordance, so Return
        // must not restart them either.
        let session = TerminalSession(
            workingDirectory: URL.temporaryDirectory,
            command: "exit 0",
            title: "Build",
            role: .run
        )
        let view = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        ) as? IbisTerminalView
        let exited = await TestSupport.waitUntil(timeout: 15) {
            session.hasStarted && !session.isRunning
        }
        #expect(exited)
        #expect(view?.returnKeyAction == nil)
    }

    @Test func titleEscapeSequencesUpdateTheTabTitle() async throws {
        let session = TerminalSession(workingDirectory: URL.temporaryDirectory, title: "Original")
        let view = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
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

    @Test func manualRenameOutranksProgramTitle() async throws {
        let session = TerminalSession(workingDirectory: URL.temporaryDirectory, title: "Original")
        let view = session.makeTerminalView(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            theme: TerminalThemeCatalog.fallbackDark,
            shellOverride: "/bin/sh"
        )
        session.setTerminalTitle(source: view, title: "program")
        #expect(session.title == "program")

        // A hand-typed name wins and pins the tab, ignoring later program titles.
        session.rename(to: "  mine  ")
        #expect(session.title == "mine")
        #expect(session.hasManualName)
        session.setTerminalTitle(source: view, title: "program2")
        #expect(session.title == "mine")

        // Clearing it reverts to the most recent program title.
        session.clearManualName()
        #expect(session.hasManualName == false)
        #expect(session.title == "program2")

        // A blank rename clears the manual name too.
        session.rename(to: "again")
        #expect(session.hasManualName)
        session.rename(to: "   ")
        #expect(session.hasManualName == false)

        _ = await TestSupport.waitUntil(timeout: 15) { session.isRunning }
        session.terminate()
    }
}
