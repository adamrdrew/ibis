import Foundation

/// A shell to launch in a terminal: its executable plus the argv[0] convention
/// that makes it a login shell (a leading "-", exactly as Terminal.app does).
struct ResolvedShell {
    let executable: String
    let args: [String]
    /// argv[0]. A leading "-" tells the shell to behave as a login shell.
    let execName: String

    var displayName: String { (executable as NSString).lastPathComponent }
}

/// Figures out which shell to run for the integrated terminal, honoring an
/// explicit user override first, then the account's login shell (via Directory
/// Services), then `$SHELL`, and finally a sensible default.
enum ShellResolver {
    static func resolve(override: String?) -> ResolvedShell {
        let path = resolvedPath(override: override)
        let name = (path as NSString).lastPathComponent
        // Launched as a login shell so it sources the user's profile.
        return ResolvedShell(executable: path, args: [], execName: "-\(name)")
    }

    /// The environment to hand the shell, as `KEY=VALUE` strings: the current
    /// process environment with a proper `TERM` and a UTF-8 locale fallback.
    static func environment(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Advertise as iTerm2 so terminal-aware tools (Claude Code, etc.) enable
        // their OSC 9 desktop-notification channel — Ibis renders those via
        // `TerminalSession`'s OSC handlers. Ibis implements the OSC 9/777
        // notification sequences iTerm2 supports; other iTerm2-proprietary
        // sequences a tool might emit are simply ignored by SwiftTerm.
        env["TERM_PROGRAM"] = "iTerm.app"
        env["TERM_PROGRAM_VERSION"] = "3.5.0"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // Project `.ibis.json` env overrides the inherited process environment.
        for (key, value) in extra { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func resolvedPath(override: String?) -> String {
        let fileManager = FileManager.default
        if let override, !override.isEmpty, fileManager.isExecutableFile(atPath: override) {
            return override
        }
        if let pw = getpwuid(getuid()) {
            let shell = String(cString: pw.pointee.pw_shell)
            if !shell.isEmpty, fileManager.isExecutableFile(atPath: shell) { return shell }
        }
        if let envShell = ProcessInfo.processInfo.environment["SHELL"],
           !envShell.isEmpty, fileManager.isExecutableFile(atPath: envShell) {
            return envShell
        }
        return "/bin/zsh"
    }
}
