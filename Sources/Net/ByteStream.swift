import Darwin
import Foundation

/// A blocking, synchronous byte channel.
///
/// Proxy handshakes are short, strictly request/response, and happen once
/// before the descriptor is handed on. Doing them synchronously keeps the
/// protocol code free of concurrency, which in turn lets it be tested over a
/// `socketpair` with no network at all.
public protocol ByteStream {
    func write(_ bytes: [UInt8]) throws
    func readExactly(_ count: Int) throws -> [UInt8]
}

/// Settings every socket the app writes to needs.
public enum SocketOptions {
    /// Makes a write to a peer that has gone fail with EPIPE rather than raise
    /// SIGPIPE. Nothing in the app ignores that signal, so one closed
    /// connection would end the whole process. Set on every socket written to.
    public static func noSIGPIPE(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Blocking or not. An accepted socket inherits the listener's
    /// non-blocking flag, which a synchronous handshake reads as an error.
    public static func setBlocking(_ fd: Int32, _ blocking: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, blocking ? flags & ~O_NONBLOCK : flags | O_NONBLOCK)
    }

    /// How long a blocking read waits before failing; 0 for as long as it takes.
    public static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// A `ByteStream` over a file descriptor. Does not own the descriptor.
public struct FileDescriptorStream: ByteStream {
    public let fd: Int32
    public init(fd: Int32) { self.fd = fd }

    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw TransportError.io("write: \(String(cString: strerror(errno)))")
            }
        }
    }

    public func readExactly(_ count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var offset = 0
        try buf.withUnsafeMutableBytes { raw in
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                if n > 0 { offset += n; continue }
                if n == 0 { throw TransportError.truncated(expected: count, got: offset) }
                if errno == EINTR { continue }
                throw TransportError.io("read: \(String(cString: strerror(errno)))")
            }
        }
        return buf
    }

    /// Reads until CRLFCRLF, for the one protocol here that is line-based.
    public func readUntilHeaderEnd(limit: Int = 8192) throws -> String {
        var accumulated = [UInt8]()
        while accumulated.count < limit {
            let byte = try readExactly(1)[0]
            accumulated.append(byte)
            if accumulated.count >= 4 && Array(accumulated.suffix(4)) == Array("\r\n\r\n".utf8) {
                return String(decoding: accumulated, as: UTF8.self)
            }
        }
        throw TransportError.io("proxy response header exceeded \(limit) bytes")
    }
}
