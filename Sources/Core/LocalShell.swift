import Darwin
import Foundation

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
    private let queue = DispatchQueue(label: "termther.shell")

    public enum Failure: Error, CustomStringConvertible {
        case openpty(String)
        case spawn(String)
        public var description: String {
            switch self {
            case .openpty(let m): "cannot open a pty: \(m)"
            case .spawn(let m): "cannot start the shell: \(m)"
            }
        }
    }

    public init() {}

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
    public func start(command: String? = nil,
                      cols: UInt16 = 80, rows: UInt16 = 24,
                      extraEnvironment: [String: String] = [:],
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable () -> Void = {}) throws {
        let shell = command ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var environment = ProcessInfo.processInfo.environment
        // TERM is how a program decides which sequences it may use at all.
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "Termther"
        environment.removeValue(forKey: "TERMTHER_SSH_HOST")
        for (key, value) in extraEnvironment { environment[key] = value }

        // Worked out before the fork: between fork and exec only
        // async-signal-safe calls are allowed, and Foundation's are not --
        // asking for the home directory there can deadlock the child on a lock
        // the parent happened to be holding.
        let home = strdup(NSHomeDirectory())
        defer { free(home) }

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

            let arguments = [shell, "-l"]
            let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
            // execve only returns on failure, so its result is discarded and
            // the _exit below is the real outcome.
            _ = withCStringArray(arguments) { argv in
                withCStringArray(environmentStrings) { envp in
                    execve(shell, argv, envp)
                }
            }
            // Only reached if exec failed; the parent sees the pty close.
            _exit(127)

        default:
            primaryFD = primary
            childPID = pid
        }

        queue.async { [primary] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(primary, $0.baseAddress, $0.count) }
                if n > 0 { onOutput(Array(buffer[0..<n])); continue }
                if n < 0 && errno == EINTR { continue }
                break
            }
            onExit()
        }
    }

    public func write(_ bytes: [UInt8]) {
        guard primaryFD >= 0 else { return }
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = Darwin.write(primaryFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                break
            }
        }
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
        if primaryFD >= 0 { close(primaryFD); primaryFD = -1 }
    }
}

private func withCStringArray<R>(_ strings: [String],
                                 _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
