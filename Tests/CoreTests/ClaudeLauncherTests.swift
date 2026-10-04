import Foundation
import Testing
@testable import Core

struct ClaudeLauncherTests {
    /// Two installed versions and the installer's symlink to the older one,
    /// as it looks while the updater is still writing the newer: that one
    /// does not answer yet.
    private func installed() throws -> AgentPaths {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        try install("2.1.9", paths)
        try install("2.1.10", paths, script: "#!/bin/sh\nexit 1\n")
        try FileManager.default.createDirectory(at: paths.command.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.command,
                                                   withDestinationURL: paths.versions.appending(path: "2.1.9"))
        return paths
    }

    private func install(_ version: String, _ paths: AgentPaths, script: String? = nil) throws {
        let file = paths.versions.appending(path: version)
        try write(script ?? "#!/bin/sh\necho \(version)\n", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    private func leftovers(_ paths: AgentPaths) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.command.deletingLastPathComponent().path)
            .filter { $0.contains("termther-") }
    }

    @Test("the symlink's version is the one it points at")
    func state() throws {
        let paths = try installed()
        #expect(ClaudeLauncher.state(paths) == .symlink(version: "2.1.9"))
        #expect(ClaudeLauncher.state(AgentPaths(.claude, home: try temporaryHome())) == .missing)
    }

    @Test("the symlink becomes a runnable copy of the version it names, not of the newest file")
    func copiesTheLinkedVersion() throws {
        let paths = try installed()
        #expect(try ClaudeLauncher.keepCopy(paths))
        #expect(ClaudeLauncher.state(paths) == .copy(version: "2.1.9"))

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.command.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o111 } == 0o111)
        #expect(try String(contentsOf: paths.command, encoding: .utf8).contains("2.1.9"))
        #expect(try leftovers(paths).isEmpty)
        #expect(!(try ClaudeLauncher.keepCopy(paths)))
    }

    @Test("when the updater links a new version, the copy follows it")
    func followsTheUpdater() throws {
        let paths = try installed()
        try ClaudeLauncher.keepCopy(paths)
        try write("#!/bin/sh\necho 2.1.11\n", to: paths.versions.appending(path: "2.1.11"))
        try FileManager.default.removeItem(at: paths.command)
        try FileManager.default.createSymbolicLink(at: paths.command,
                                                   withDestinationURL: paths.versions.appending(path: "2.1.11"))
        #expect(try ClaudeLauncher.keepCopy(paths))
        #expect(ClaudeLauncher.state(paths) == .copy(version: "2.1.11"))
        #expect(try String(contentsOf: paths.command, encoding: .utf8).contains("2.1.11"))
    }

    @Test("a launcher the app did not make, one pointing elsewhere, and a missing one are left alone")
    func leavesOthersAlone() throws {
        let own = try installed()
        try FileManager.default.removeItem(at: own.command)
        try write("#!/bin/sh\necho mine\n", to: own.command)
        #expect(!(try ClaudeLauncher.keepCopy(own)))
        #expect(try String(contentsOf: own.command, encoding: .utf8).contains("mine"))

        let elsewhere = try installed()
        let other = try temporaryHome().appending(path: "2.1.9")
        try write("#!/bin/sh\necho other\n", to: other)
        try FileManager.default.removeItem(at: elsewhere.command)
        try FileManager.default.createSymbolicLink(at: elsewhere.command, withDestinationURL: other)
        #expect(!(try ClaudeLauncher.keepCopy(elsewhere)))
        #expect(ClaudeLauncher.state(elsewhere) == .symlink(version: "2.1.9"))

        let missing = try installed()
        try FileManager.default.removeItem(at: missing.command)
        #expect(!(try ClaudeLauncher.keepCopy(missing)))
        #expect(ClaudeLauncher.state(missing) == .missing)
    }

    @Test("a relative symlink into the versions directory counts as the installer's")
    func relativeLink() throws {
        let paths = try installed()
        try FileManager.default.removeItem(at: paths.command)
        let relative = paths.versions.appending(path: "2.1.10").path
            .replacingOccurrences(of: paths.command.deletingLastPathComponent().deletingLastPathComponent().path,
                                  with: "..")
        try FileManager.default.createSymbolicLink(atPath: paths.command.path, withDestinationPath: relative)
        #expect(try ClaudeLauncher.keepCopy(paths))
        #expect(ClaudeLauncher.state(paths) == .copy(version: "2.1.10"))
    }

    @Test("the copy moves on to the newest version once that one answers, and clears the older ones, as the updater will not")
    func followsTheNewestVersion() throws {
        let paths = try installed()
        try ClaudeLauncher.keepCopy(paths)
        #expect(!(try ClaudeLauncher.keepCopy(paths)))
        #expect(ClaudeLauncher.state(paths) == .copy(version: "2.1.9"))

        try install("2.1.10", paths)
        #expect(try ClaudeLauncher.keepCopy(paths))
        #expect(ClaudeLauncher.state(paths) == .copy(version: "2.1.10"))
        #expect(try String(contentsOf: paths.command, encoding: .utf8).contains("2.1.10"))
        #expect(try leftovers(paths).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.versions.path) == ["2.1.10"])
    }
}
