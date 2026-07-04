import Testing
import Foundation
@testable import ibis

@Suite struct ShellResolverTests {
    @Test func explicitExecutableOverrideIsHonored() {
        let shell = ShellResolver.resolve(override: "/bin/zsh")
        #expect(shell.executable == "/bin/zsh")
        #expect(shell.args.isEmpty)
        // argv[0] carries a leading "-" so the shell runs as a login shell.
        #expect(shell.execName == "-zsh")
        #expect(shell.displayName == "zsh")
    }

    @Test func nonExecutableOverrideFallsBack() {
        let shell = ShellResolver.resolve(override: "/definitely/not/a/shell-\(UUID().uuidString)")
        #expect(shell.executable != "/definitely/not/a/shell")
        #expect(FileManager.default.isExecutableFile(atPath: shell.executable))
        #expect(shell.execName.hasPrefix("-"))
    }

    @Test func defaultResolvesToARealLoginShell() {
        let shell = ShellResolver.resolve(override: nil)
        #expect(FileManager.default.isExecutableFile(atPath: shell.executable))
        #expect(shell.execName == "-\(shell.displayName)")
    }

    @Test func environmentSetsTerminalIdentifiers() {
        let env = ShellResolver.environment()
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("TERM_PROGRAM=Ibis"))
    }

    @Test func environmentMergesExtraValues() {
        let env = ShellResolver.environment(extra: ["IBIS_TEST_KEY": "42"])
        #expect(env.contains("IBIS_TEST_KEY=42"))
    }
}
