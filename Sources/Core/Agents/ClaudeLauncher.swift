import Foundation

/// What `~/.local/bin/claude` is.
///
/// Claude Code's installer leaves it a symlink to a versioned binary, so the
/// process shows up in `ps`, Activity Monitor and a terminal's title as
/// `2.1.285`. A real copy named `claude` shows as `claude`, so the app keeps
/// it one; the copy remembers its version in a sidecar file beside the
/// versions directory, since the binary itself will not say.
public enum ClaudeLauncher {
    public enum State: Equatable, Sendable {
        case symlink(version: String)
        /// `version` is "" for a copy this app did not make.
        case copy(version: String)
        case missing
    }

    public enum Failure: Error, CustomStringConvertible {
        case incomplete
        case rename(Int32)

        public var description: String {
            switch self {
            case .incomplete: "the copy of Claude Code came out a different size from the original"
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

    /// Turns the installer's symlink into a copy of the version it names,
    /// and moves a copy of ours on to the newest version once that one
    /// answers `--version` -- half a binary does not run -- since the updater
    /// leaves a launcher that is a file alone. True when it copied. A
    /// launcher this app did not make, a symlink pointing elsewhere, and a
    /// missing one are left as they are.
    @discardableResult
    public static func keepCopy(_ paths: AgentPaths) throws -> Bool {
        let current = state(paths)
        switch current {
        case .symlink(let version) where pointsIntoVersions(paths) && !version.isEmpty:
            try copy(version, paths, replacing: current)
            return true
        case .copy(let version) where !version.isEmpty:
            if let newest = installedVersions(paths).last,
               newest.compare(version, options: .numeric) == .orderedDescending, answers(newest, paths) {
                try copy(newest, paths, replacing: current)
                removeVersions(olderThan: newest, paths)
                return true
            }
            removeVersions(olderThan: version, paths)
            return false
        default:
            return false
        }
    }

    /// Oldest first.
    private static func installedVersions(_ paths: AgentPaths) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.versions.path)) ?? [])
            .filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// The installer's cleanup is off while the launcher is a file -- it
    /// cannot tell which version the file is -- so every version it ever
    /// downloaded would stay, a quarter of a gigabyte each. The copy is the
    /// one that runs; older ones are of no use. A process still running
    /// one keeps it open, deleted or not.
    private static func removeVersions(olderThan kept: String, _ paths: AgentPaths) {
        for name in installedVersions(paths).prefix(while: { $0.compare(kept, options: .numeric) == .orderedAscending }) {
            try? FileManager.default.removeItem(at: paths.versions.appending(path: name))
        }
    }

    /// Whether the version runs and says it is itself.
    private static func answers(_ version: String, _ paths: AgentPaths) -> Bool {
        guard let run = try? Subprocess.run(paths.versions.appending(path: version), ["--version"])
        else { return false }
        return run.status == 0 && String(decoding: run.output, as: UTF8.self).contains(version)
    }

    /// Whether the symlink's target is in the versions directory, wherever
    /// the link was written relative to.
    private static func pointsIntoVersions(_ paths: AgentPaths) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: paths.command.path)
        else { return false }
        let target = URL(fileURLWithPath: destination, relativeTo: paths.command.deletingLastPathComponent())
        return target.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
            == paths.versions.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Replaces the launcher with a copy of `version`, named `claude`.
    private static func copy(_ version: String, _ paths: AgentPaths, replacing current: State) throws {
        let manager = FileManager.default
        let source = paths.versions.appending(path: version)
        // A name of its own: two refreshes at once must not share one file.
        let staged = paths.command.appendingPathExtension("termther-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        let size = { (url: URL) in (try? manager.attributesOfItem(atPath: url.path))?[.size] as? UInt64 }
        guard let copied = size(staged), copied > 0, copied == size(source) else { throw Failure.incomplete }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // Before the swap: a launcher that is a copy with no record of its
        // version reads as someone else's file and is never touched again.
        try Data(version.utf8).write(to: sidecar(paths), options: .atomic)
        // The updater may have moved the launcher on while this copied; its
        // newer choice stands, and the change it made brings another pass.
        // A copy already reads as the new version: the record just changed.
        let now = state(paths)
        guard now == current || now == .copy(version: version) else { return }
        // Over the launcher in one step, so there is never a moment without one.
        guard rename(staged.path, paths.command.path) == 0 else { throw Failure.rename(errno) }
    }

    static func sidecar(_ paths: AgentPaths) -> URL {
        paths.versions.deletingLastPathComponent().appending(path: "termther-copy-version")
    }
}
