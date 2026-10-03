import Foundation
import Testing
@testable import Core

struct ClaudeLauncherTests {
    /// Two installed versions and the installer's symlink to the older one,
    /// as an install that has not updated the link yet would look.
    private func installed() throws -> AgentPaths {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        for version in ["2.1.10", "2.1.9"] {
            try write("#!/bin/sh\necho \(version)\n", to: paths.versions.appending(path: version))
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: paths.versions.appending(path: version).path)
        }
        try FileManager.default.createDirectory(at: paths.command.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.command,
                                                   withDestinationURL: paths.versions.appending(path: "2.1.9"))
        return paths
    }

    @Test("versions sort as numbers, and the symlink's version is the one it points at")
    func state() throws {
        let paths = try installed()
        #expect(ClaudeLauncher.installedVersions(paths) == ["2.1.9", "2.1.10"])
        #expect(ClaudeLauncher.latestVersion(paths) == "2.1.10")
        #expect(ClaudeLauncher.state(paths) == .symlink(version: "2.1.9"))
        #expect(ClaudeLauncher.state(AgentPaths(.claude, home: try temporaryHome())) == .missing)
    }

    @Test("a copy replaces the symlink with the newest binary, runnable and remembering its version")
    func useCopy() throws {
        let paths = try installed()
        try ClaudeLauncher.useCopy(paths)
        #expect(ClaudeLauncher.state(paths) == .copy(version: "2.1.10"))

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.command.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o111 } == 0o111)
        #expect(try String(contentsOf: paths.command, encoding: .utf8).contains("2.1.10"))
        #expect(!FileManager.default.fileExists(atPath: paths.command.appendingPathExtension("termther-tmp").path))

        try ClaudeLauncher.restoreSymlink(paths)
        #expect(ClaudeLauncher.state(paths) == .symlink(version: "2.1.10"))
        #expect(!FileManager.default.fileExists(atPath: ClaudeLauncher.sidecar(paths).path))
    }

    @Test("keeping a copy follows the newest version and does nothing while it is current")
    func keepCopy() throws {
        let paths = try installed()
        #expect(try ClaudeLauncher.keepCopy(paths))
        #expect(!(try ClaudeLauncher.keepCopy(paths)))
        #expect(ClaudeLauncher.state(paths) == .copy(version: "2.1.10"))

        // The updater installs a version and points the symlink at it.
        try write("#!/bin/sh\necho 2.1.11\n", to: paths.versions.appending(path: "2.1.11"))
        try FileManager.default.removeItem(at: paths.command)
        try FileManager.default.createSymbolicLink(at: paths.command,
                                                   withDestinationURL: paths.versions.appending(path: "2.1.11"))
        #expect(try ClaudeLauncher.keepCopy(paths))
        #expect(ClaudeLauncher.state(paths) == .copy(version: "2.1.11"))
        #expect(try String(contentsOf: paths.command, encoding: .utf8).contains("2.1.11"))
    }

    @Test("with nothing installed there is nothing to copy")
    func nothingInstalled() throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        #expect(throws: ClaudeLauncher.Failure.self) { try ClaudeLauncher.useCopy(paths) }
    }
}
