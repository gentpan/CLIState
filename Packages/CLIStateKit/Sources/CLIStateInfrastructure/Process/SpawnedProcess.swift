import CLIStateDomain
import Darwin
import Foundation

/// A child started with `posix_spawn` as the leader of its own process group,
/// stdin on /dev/null and stdout/stderr on non-blocking pipes owned by the caller.
struct SpawnedProcess {
    let pid: pid_t
    let stdout: Int32
    let stderr: Int32

    static func launch(_ command: Command, environment: [String: String]) throws -> SpawnedProcess {
        let executable = command.executable
        // No PATH search here: providers resolve executables through the user's shell PATH.
        guard executable.hasPrefix("/"), POSIXFile.isExecutableRegularFile(executable) else {
            throw CommandError.executableNotFound(executable)
        }
        if let directory = command.workingDirectory, !POSIXFile.isDirectory(directory) {
            throw CommandError.launchFailed(executable: executable, reason: "working directory not found: \(directory)")
        }

        let arguments = [executable] + command.arguments
        let variables = environment.map { "\($0.key)=\($0.value)" }
        // C strings end at NUL; refuse instead of silently truncating an argument.
        guard !(arguments + variables).contains(where: { $0.utf8.contains(0) }) else {
            throw CommandError.launchFailed(executable: executable, reason: "argument or environment contains a NUL byte")
        }

        let stdoutPipe = try makePipe(executable)
        let stderrPipe: (read: Int32, write: Int32)
        do {
            stderrPipe = try makePipe(executable)
        } catch {
            close(stdoutPipe.read)
            close(stdoutPipe.write)
            throw error
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO)
        if let directory = command.workingDirectory {
            if #available(macOS 26, *) {
                posix_spawn_file_actions_addchdir(&fileActions, directory)
            } else {
                posix_spawn_file_actions_addchdir_np(&fileActions, directory)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT: the child inherits only fds 0–2, never pipes of other
        // concurrently spawned commands (which would delay their EOF).
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        // Ignored signals survive exec; reset them so SIGPIPE/SIGTERM behave normally in the child.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = variables.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        close(stdoutPipe.write)
        close(stderrPipe.write)
        guard status == 0 else {
            close(stdoutPipe.read)
            close(stderrPipe.read)
            throw CommandError.launchFailed(executable: executable, reason: String(cString: strerror(status)))
        }

        setNonBlocking(stdoutPipe.read)
        setNonBlocking(stderrPipe.read)
        return SpawnedProcess(pid: pid, stdout: stdoutPipe.read, stderr: stderrPipe.read)
    }

    private static func makePipe(_ executable: String) throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw CommandError.launchFailed(executable: executable, reason: String(cString: strerror(errno)))
        }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        return (fds[0], fds[1])
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }
}
