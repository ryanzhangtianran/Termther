import CSSH2
import Foundation

/// A file on the far end.
public struct RemoteFile: Sendable, Equatable {
    public enum Kind: Sendable { case file, directory, symlink, other }

    public var name: String
    public var kind: Kind
    public var size: UInt64
    public var permissions: UInt32
    public var modified: Date?

    public var isDirectory: Bool { kind == .directory }
}

extension SSHSession {
    /// An open SFTP subsystem on this session.
    public struct SFTP: Sendable, Hashable {
        let id: Int
    }

    /// Opens the SFTP subsystem.
    ///
    /// It is a channel like any other, so it shares the session's connection
    /// and its EAGAIN pump; a file transfer and an interactive shell run side
    /// by side over one TCP connection.
    public func openSFTP() async throws -> SFTP {
        let raw = try requireSession()
        let handle = try await retryPointer("sftp_init") { libssh2_sftp_init(raw) }
        let sftp = SFTP(id: nextSFTPID)
        nextSFTPID += 1
        sftpSessions[sftp] = handle
        return sftp
    }

    public func closeSFTP(_ sftp: SFTP) async {
        guard let handle = sftpSessions.removeValue(forKey: sftp) else { return }
        _ = try? await retry("sftp_shutdown") { libssh2_sftp_shutdown(handle) }
    }

    /// Lists a directory.
    public func list(_ sftp: SFTP, path: String) async throws -> [RemoteFile] {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }

        let directory = try await retryPointer("sftp_opendir") {
            libssh2_sftp_open_ex(session, path, UInt32(path.utf8.count), 0, 0,
                                 LIBSSH2_SFTP_OPENDIR)
        }
        defer { _ = libssh2_sftp_close_handle(directory) }

        var entries: [RemoteFile] = []
        var name = [CChar](repeating: 0, count: 512)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()

        while true {
            let n = try await retry("sftp_readdir") {
                libssh2_sftp_readdir_ex(directory, &name, name.count, nil, 0, &attributes)
            }
            // Zero means the listing is complete, not that nothing was read.
            if n == 0 { break }

            // The buffer is reused, so only the bytes this entry wrote count.
            let entryName = String(decoding: name.prefix(Int(n)).map { UInt8(bitPattern: $0) },
                                   as: UTF8.self)
            guard entryName != ".", entryName != ".." else { continue }
            entries.append(RemoteFile(attributes, name: entryName))
        }
        return entries
    }

    public func stat(_ sftp: SFTP, path: String) async throws -> RemoteFile? {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        do {
            try await retry("sftp_stat") {
                libssh2_sftp_stat_ex(session, path, UInt32(path.utf8.count),
                                     LIBSSH2_SFTP_STAT, &attributes)
            }
        } catch {
            return nil   // "not found" is an answer, not a failure
        }
        return RemoteFile(attributes, name: (path as NSString).lastPathComponent)
    }

    /// Reads a whole file.
    ///
    /// `onProgress` reports bytes so far, so a UI can show a transfer without
    /// the transfer knowing a UI exists.
    public func read(_ sftp: SFTP, path: String,
                     onProgress: (@Sendable (UInt64) -> Void)? = nil) async throws -> Data {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }

        let file = try await retryPointer("sftp_open") {
            libssh2_sftp_open_ex(session, path, UInt32(path.utf8.count),
                                 UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
        }
        defer { _ = libssh2_sftp_close_handle(file) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = try await retryInt("sftp_read") {
                buffer.withUnsafeMutableBytes { raw in
                    libssh2_sftp_read(file, raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                      raw.count)
                }
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            onProgress?(UInt64(data.count))
        }
        return data
    }

    /// Writes a whole file, creating or truncating it.
    public func write(_ sftp: SFTP, path: String, data: Data,
                      permissions: Int = 0o644,
                      onProgress: (@Sendable (UInt64) -> Void)? = nil) async throws {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }

        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        let file = try await retryPointer("sftp_open") {
            libssh2_sftp_open_ex(session, path, UInt32(path.utf8.count),
                                 flags, Int(permissions), LIBSSH2_SFTP_OPENFILE)
        }
        defer { _ = libssh2_sftp_close_handle(file) }

        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = try await retryInt("sftp_write") {
                bytes.withUnsafeBytes { raw in
                    libssh2_sftp_write(
                        file,
                        raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                        min(64 * 1024, raw.count - offset))
                }
            }
            // Partial writes are normal: the channel window fills and the rest
            // goes out as the far end acknowledges.
            offset += written
            onProgress?(UInt64(offset))
        }
    }

    public func mkdir(_ sftp: SFTP, path: String, permissions: Int = 0o755) async throws {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }
        try await retry("sftp_mkdir") {
            libssh2_sftp_mkdir_ex(session, path, UInt32(path.utf8.count), Int(permissions))
        }
    }

    public func remove(_ sftp: SFTP, path: String) async throws {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }
        try await retry("sftp_unlink") {
            libssh2_sftp_unlink_ex(session, path, UInt32(path.utf8.count))
        }
    }

    public func rmdir(_ sftp: SFTP, path: String) async throws {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }
        try await retry("sftp_rmdir") {
            libssh2_sftp_rmdir_ex(session, path, UInt32(path.utf8.count))
        }
    }

    public func rename(_ sftp: SFTP, from: String, to: String) async throws {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }
        try await retry("sftp_rename") {
            libssh2_sftp_rename_ex(session,
                                   from, UInt32(from.utf8.count),
                                   to, UInt32(to.utf8.count),
                                   Int(LIBSSH2_SFTP_RENAME_OVERWRITE))
        }
    }

    /// Resolves a path the way the far end sees it, which is how "~" and
    /// relative paths become something a UI can display.
    public func realpath(_ sftp: SFTP, path: String) async throws -> String {
        guard let session = sftpSessions[sftp] else { throw SSHError.socket("sftp closed") }
        var buffer = [CChar](repeating: 0, count: 1024)
        let n = try await retry("sftp_realpath") {
            libssh2_sftp_symlink_ex(session, path, UInt32(path.utf8.count),
                                    &buffer, UInt32(buffer.count), LIBSSH2_SFTP_REALPATH)
        }
        return String(decoding: buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension RemoteFile {
    init(_ attributes: LIBSSH2_SFTP_ATTRIBUTES, name: String) {
        let permissions = UInt32(attributes.permissions)
        let kind: Kind = switch permissions & 0o170000 {
        case 0o040000: .directory
        case 0o100000: .file
        case 0o120000: .symlink
        default: .other
        }
        self.init(
            name: name,
            kind: kind,
            size: attributes.filesize,
            permissions: permissions & 0o7777,
            modified: attributes.mtime > 0
                ? Date(timeIntervalSince1970: TimeInterval(attributes.mtime))
                : nil)
    }
}
