import Darwin
import Foundation
import Net

/// A shell running on this machine, on a real pty.
///
/// A terminal that only speaks SSH is a remote viewer, not a terminal. The
/// local shell is a first-class session, and it is also the simplest possible
/// byte source -- useful long before any network exists.
///
/// The far end must be a pty rather than a pipe: programs check `isatty` to
/// decide whether to emit colour, whether to line-buffer, and whether they may
/// take over the screen at all.
public final class LocalShell: @unchecked Sendable {
    public private(set) var primaryFD: Int32 = -1
    private var childPID: pid_t = -1

    /// The shell's process, once started: what zsh calls `$$`.
    public var processID: pid_t? { childPID > 0 ? childPID : nil }

    /// Where the shell is right now, asked of the kernel rather than of the
    /// shell: zsh only reports its directory (OSC 7) inside Apple's Terminal.
    public var workingDirectory: String? {
        guard childPID > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(childPID, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
    }
    private let queue = DispatchQueue(label: "termther.shell")
    private var outputSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    public enum Failure: Error, CustomStringConvertible {
        case openpty(String)
        public var description: String {
            switch self {
            case .openpty(let m): "cannot open a pty: \(m)"
            }
        }
    }

    /// Run first, in the shell, before it takes the terminal as usual --
    /// `claude --resume <id>`, say. The shell is interactive throughout, so
    /// the user's rc files are read and the tab is a plain terminal after.
    private let command: String?
    /// Where the shell starts; the home directory by default.
    private let directory: String?

    public init(command: String? = nil, directory: String? = nil) {
        self.command = command
        self.directory = directory
    }

    /// Starts the shell and streams its output to `onOutput`.
    ///
    /// Uses `forkpty` rather than `posix_spawn`, because a terminal needs more
    /// than a pty on the child's file descriptors: the pty has to be the
    /// child's *controlling terminal*, in its own session, with the child in
    /// the foreground process group. That is what makes the line discipline do
    /// its job -- Ctrl+C becoming SIGINT, Ctrl+D becoming end-of-file, Ctrl+Z
    /// suspending. With only the descriptors wired up, those bytes arrive and
    /// nothing happens, which looks exactly like broken key handling.
    ///
    /// `forkpty` performs the whole construction: fork, `setsid`, `TIOCSCTTY`,
    /// and the descriptor dance.
    /// `extraEnvironment` is added to what the shell inherits, for the
    /// variables a terminal is meant to start with rather than be told about.
    public func start(cols: UInt16 = 80, rows: UInt16 = 24,
                      extraEnvironment: [String: String] = [:],
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable () -> Void = {}) throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var environment = ProcessInfo.processInfo.environment
        // TERM is how a program decides which sequences it may use at all.
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "Termther"
        environment.removeValue(forKey: "TERMTHER_SSH_HOST")
        // `termther ssh` is handed a password this way; it is not the shell's.
        environment.removeValue(forKey: "SSHPASS")
        for (key, value) in extraEnvironment { environment[key] = value }

        // Everything the child needs is built before the fork: between fork
        // and exec only async-signal-safe calls are allowed, and building
        // strings is not -- it allocates, and can deadlock the child on a
        // lock another thread of the parent happened to be holding.
        let home = strdup(directory ?? NSHomeDirectory())
        let path = strdup(shell)
        // `-i -c` runs the command in an interactive shell -- rc files read,
        // job control on -- and `exec` at the end hands the terminal to a
        // plain login shell in the same process once it is done.
        var argv = [strdup(shell), strdup("-l"), nil]
        if let command {
            argv = [strdup(shell), strdup("-l"), strdup("-i"), strdup("-c"),
                    strdup("\(command); exec \(shellQuoted(shell)) -l"), nil]
        }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            free(home)
            free(path)
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var primary: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&primary, nil, nil, &size)

        switch pid {
        case -1:
            throw Failure.openpty(String(cString: strerror(errno)))

        case 0:
            // The child. Only async-signal-safe work between fork and exec.
            //
            // Start in the user's home. An app launched from Finder inherits
            // "/" as its working directory, and without this every new terminal
            // opens at the root of the disk.
            if let home { _ = chdir(home) }
            _ = argv.withUnsafeMutableBufferPointer { argv in
                envp.withUnsafeMutableBufferPointer { envp in
                    execve(path, argv.baseAddress, envp.baseAddress)
                }
            }
            // Only reached if exec failed; the parent sees the pty close.
            _exit(127)

        default:
            primaryFD = primary
            childPID = pid
        }

        // Reaped when it exits, or it stays a zombie until the app quits.
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak exit] in
            _ = waitpid(pid, nil, WNOHANG)
            exit?.cancel()
        }
        exit.resume()
        exitSource = exit
        // Already gone before the source was watching: nothing would fire.
        if waitpid(pid, nil, WNOHANG) == pid { exit.cancel() }

        // A source rather than a thread blocked in read(): the descriptor is
        // closed in its cancel handler, after the last read, so a read can
        // never reach a number the kernel has since given to something else.
        let output = DispatchSource.makeReadSource(fileDescriptor: primary, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        output.setEventHandler { [weak output] in
            let n = buffer.withUnsafeMutableBytes { read(primary, $0.baseAddress, $0.count) }
            if n > 0 { onOutput(Array(buffer[0..<n])); return }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
            output?.cancel()   // end of file, or EIO once the shell is gone
        }
        output.setCancelHandler {
            close(primary)
            onExit()
        }
        output.resume()
        outputSource = output
    }

    public func write(_ bytes: [UInt8]) {
        guard primaryFD >= 0 else { return }
        try? FileDescriptorStream(fd: primaryFD).write(bytes)
    }

    /// Tells the pty the window changed, which is what makes SIGWINCH fire and
    /// full-screen programs redraw at the new size.
    public func setWindowSize(cols: UInt16, rows: UInt16) {
        guard primaryFD >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(primaryFD, TIOCSWINSZ, &size)
    }

    public func terminate() {
        // The whole process group, so a shell's children go too rather than
        // being reparented and left running.
        if childPID > 0 { killpg(childPID, SIGHUP); childPID = -1 }
        // The descriptor is closed by the source's cancel handler.
        primaryFD = -1
        outputSource?.cancel()
    }
}
