import Foundation

/// What `~/.local/bin/claude` is.
///
/// Claude Code's installer leaves it a symlink to a versioned binary, so the
/// process shows up in `ps`, Activity Monitor and a terminal's title as
/// `2.1.285`. A real copy named `claude` shows as `claude`. Switching between
/// the two is what this does; the copy remembers its version in a sidecar
/// file beside the versions directory, since the binary itself will not say.
public enum ClaudeLauncher {
    public enum State: Equatable, Sendable {
        case symlink(version: String)
        /// `version` is "" for a copy this app did not make.
        case copy(version: String)
        case missing
    }

    public enum Failure: Error, CustomStringConvertible {
        case noVersions
        case rename(Int32)

        public var description: String {
            switch self {
            case .noVersions: "no Claude Code version is installed to point the launcher at"
            case .rename(let errno): "cannot replace the launcher: \(String(cString: strerror(errno)))"
            }
        }
    }

    public static func state(_ paths: AgentPaths) -> State {
        let manager = FileManager.default
        guard let type = (try? manager.attributesOfItem(atPath: paths.command.path))?[.type]
            as? FileAttributeType else { return .missing }
        if type == .typeSymbolicLink {
            let destination = (try? manager.destinationOfSymbolicLink(atPath: paths.command.path)) ?? ""
            return .symlink(version: URL(fileURLWithPath: destination).lastPathComponent)
        }
        let recorded = try? String(contentsOf: sidecar(paths), encoding: .utf8)
        return .copy(version: recorded?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Oldest first.
    public static func installedVersions(_ paths: AgentPaths) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.versions.path)) ?? []
        return names.filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    public static func latestVersion(_ paths: AgentPaths) -> String? { installedVersions(paths).last }

    /// Makes the launcher a copy of the newest version unless it is one
    /// already; true when it copied. Claude Code's updater installs a new
    /// version and points the symlink at it, which undoes `useCopy`, so
    /// this is run again whenever either directory changes.
    @discardableResult
    public static func keepCopy(_ paths: AgentPaths) throws -> Bool {
        guard let latest = latestVersion(paths), state(paths) != .copy(version: latest) else { return false }
        try useCopy(paths)
        return true
    }

    /// Replaces the launcher with a copy of the newest version, named `claude`.
    public static func useCopy(_ paths: AgentPaths) throws {
        guard let version = latestVersion(paths) else { throw Failure.noVersions }
        let manager = FileManager.default
        let staged = staging(paths)
        try? manager.removeItem(at: staged)
        try manager.copyItem(at: paths.versions.appending(path: version), to: staged)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        try install(staged, paths: paths)
        try Data(version.utf8).write(to: sidecar(paths), options: .atomic)
    }

    /// Puts the installer's symlink back, to the newest version.
    public static func restoreSymlink(_ paths: AgentPaths) throws {
        guard let version = latestVersion(paths) else { throw Failure.noVersions }
        let staged = staging(paths)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createSymbolicLink(
            at: staged, withDestinationURL: paths.versions.appending(path: version))
        try install(staged, paths: paths)
        try? FileManager.default.removeItem(at: sidecar(paths))
    }

    /// Moves what was staged over the launcher in one step, so there is never
    /// a moment without one.
    private static func install(_ staged: URL, paths: AgentPaths) throws {
        try FileManager.default.createDirectory(at: paths.command.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard rename(staged.path, paths.command.path) == 0 else { throw Failure.rename(errno) }
    }

    private static func staging(_ paths: AgentPaths) -> URL {
        paths.command.appendingPathExtension("termther-tmp")
    }

    static func sidecar(_ paths: AgentPaths) -> URL {
        paths.versions.deletingLastPathComponent().appending(path: "termther-copy-version")
    }
}
