import Foundation
import Darwin

/// Reads live information about the process running in a terminal's pseudo-tty —
/// the foreground job's name and its working directory — straight from the kernel
/// via `libproc`. Used to build terminal tab titles (the working directory / the
/// active process), the way iTerm and Terminal.app do. Pure, side-effect-free
/// reads of an existing child process, so they're cheap enough to poll.
enum TerminalProcessInfo {
    /// The executable name (basename) of the foreground process group on the tty
    /// behind `childfd` — e.g. `zsh` while idle, `vim`/`node` while a program
    /// runs. Falls back to `shellPid`'s own name when the foreground group can't
    /// be read. Nil if nothing resolves.
    nonisolated static func foregroundName(childfd: Int32, shellPid: pid_t) -> String? {
        var pid = tcgetpgrp(childfd)
        if pid <= 0 { pid = shellPid }
        guard pid > 0 else { return nil }
        return executableName(pid: pid) ?? (pid != shellPid ? executableName(pid: shellPid) : nil)
    }

    /// A program running in the foreground of a terminal — what closing that tab
    /// would kill.
    struct ForegroundJob: Sendable, Equatable {
        let pid: pid_t
        /// The executable's basename, when the kernel would tell us.
        let name: String?
    }

    /// The foreground job on the tty behind `childfd`, or nil when the shell
    /// itself owns the terminal — i.e. it's sitting at its prompt.
    ///
    /// This is the signal terminal emulators use to decide whether closing a tab
    /// needs confirmation, and it needs no list of "interesting" program names.
    /// The kernel tracks one *foreground process group* per tty: a shell at its
    /// prompt is that group, and the instant it runs a command, the command's
    /// group takes the tty over while the shell blocks in `waitpid`. So a
    /// foreground group that isn't the shell's own group means a program is
    /// running, whatever it happens to be. It also gets the subtle cases right
    /// for free — a job backgrounded with `&` never owns the tty, so it
    /// correctly doesn't count, and neither does a suspended one.
    nonisolated static func foregroundJob(childfd: Int32, shellPid: pid_t) -> ForegroundJob? {
        guard childfd >= 0, shellPid > 0 else { return nil }
        let foreground = tcgetpgrp(childfd)
        // Compare against the shell's process *group*, not its pid: the group is
        // what owns the tty. (They're equal for a shell started on its own pty,
        // which leads its group — but reading the group says what we mean.)
        let shellGroup = getpgid(shellPid)
        guard foreground > 0, shellGroup > 0, foreground != shellGroup else { return nil }
        // A process group's id is the pid of its leader — the job's first
        // process — so this names the program the user actually started.
        return ForegroundJob(pid: foreground, name: executableName(pid: foreground))
    }

    /// The current working directory of the process `pid`, read from its vnode
    /// info. For a shell this tracks `cd`; for a running program it's that
    /// program's cwd (usually the same directory).
    nonisolated static func workingDirectory(pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// The working directory of the foreground process, falling back to the
    /// shell's own cwd — matches what `foregroundName` reports on.
    nonisolated static func foregroundWorkingDirectory(childfd: Int32, shellPid: pid_t) -> URL? {
        var pid = tcgetpgrp(childfd)
        if pid <= 0 { pid = shellPid }
        return workingDirectory(pid: pid) ?? workingDirectory(pid: shellPid)
    }

    /// The basename of `pid`'s executable path, via `proc_pidpath`.
    private nonisolated static func executableName(pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` (4 * MAXPATHLEN) isn't bridged into Swift's
        // Darwin module, so size the buffer to its value directly.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
