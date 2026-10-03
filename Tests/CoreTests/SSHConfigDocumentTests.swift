import Foundation
import Testing
@testable import Core

/// Editing the user's own `~/.ssh/config`.
///
/// Every test compares whole files: the promise is that nothing outside the
/// edited lines moves, and only the full text can show that.
struct SSHConfigDocumentTests {
    /// A config with everything an editor must not disturb.
    let sample = """
    # personal machines
    Include ~/.ssh/work.conf

    Host *
        ServerAliveInterval 30

    # the lab box
    Host gpu
        HostName gpu.lab.example.edu
        User ryan
        # tags: lab
        ForwardAgent yes

    Host web db
        User deploy

    Match host *.internal
        ProxyJump bastion

    Host pi
      HostName 192.168.1.8

    """

    @Test("an untouched document writes back exactly what it read")
    func roundTrip() {
        #expect(SSHConfigDocument(text: sample).text == sample)
    }

    @Test("only single, concrete hosts are editable; the rest are listed as they are")
    func entries() {
        let document = SSHConfigDocument(text: sample)
        #expect(document.entries.map(\.alias) == ["gpu", "pi"])
        #expect(document.entries.first == .init(alias: "gpu", hostName: "gpu.lab.example.edu",
                                                user: "ryan", forwardAgent: "yes"))
        #expect(document.otherBlocks == ["Host *", "Host web db", "Match host *.internal"])
    }

    @Test("changing a field rewrites that line alone, in its own indentation")
    func editInPlace() throws {
        var document = SSHConfigDocument(text: sample)
        var gpu = try #require(document.entries.first)
        gpu.user = "tzhang"
        gpu.port = "2222"
        try document.save(gpu, replacing: "gpu")
        #expect(document.text == sample.replacingOccurrences(of: """
            User ryan
            # tags: lab
            ForwardAgent yes
        """, with: """
            User tzhang
            # tags: lab
            ForwardAgent yes
            Port 2222
        """))
    }

    @Test("clearing a field removes its line; renaming touches only the Host line")
    func clearAndRename() throws {
        var document = SSHConfigDocument(text: sample)
        var pi = try #require(document.entries.last)
        pi.alias = "raspberry"
        pi.hostName = ""
        pi.user = "pi"
        try document.save(pi, replacing: "pi")
        #expect(document.text == sample.replacingOccurrences(of: """
        Host pi
          HostName 192.168.1.8
        """, with: """
        Host raspberry
          User pi
        """))
    }

    @Test("removing a host takes its own comment and leaves no double blank line")
    func remove() throws {
        var document = SSHConfigDocument(text: sample)
        try document.remove(alias: "gpu")
        #expect(document.text == sample.replacingOccurrences(of: """
        # the lab box
        Host gpu
            HostName gpu.lab.example.edu
            User ryan
            # tags: lab
            ForwardAgent yes


        """, with: ""))
    }

    @Test("a new host is appended after a blank line, keeping the final newline")
    func add() throws {
        var document = SSHConfigDocument(text: sample)
        try document.save(.init(alias: "new", hostName: "10.0.0.5", user: "me",
                                identityFile: "~/.ssh/my key"), replacing: nil)
        #expect(document.text == sample + """

        Host new
            HostName 10.0.0.5
            User me
            IdentityFile "~/.ssh/my key"

        """)
    }

    @Test("names that ssh would read as patterns, or that exist already, are refused")
    func refusals() {
        var document = SSHConfigDocument(text: sample)
        #expect(throws: SSHConfigDocument.EditError.invalidAlias) {
            try document.save(.init(alias: "web*"), replacing: nil)
        }
        #expect(throws: SSHConfigDocument.EditError.duplicateAlias("pi")) {
            try document.save(.init(alias: "pi"), replacing: "gpu")
        }
        #expect(document.text == sample)
    }

    @Test("saving keeps a backup and the permissions, and refuses a file changed meanwhile")
    func saving() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sshconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config")
        try sample.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        var document = SSHConfigDocument(text: sample)
        try document.remove(alias: "pi")
        try document.save(to: url, original: sample)

        #expect(try String(contentsOf: url, encoding: .utf8) == document.text)
        #expect(try String(contentsOf: url.appendingPathExtension("termther-backup"),
                           encoding: .utf8) == sample)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        #expect(permissions as? Int == 0o600)

        // Now stale: the file holds the edit, not `sample`.
        #expect(throws: SSHConfigDocument.SaveError.changedOnDisk) {
            try document.save(to: url, original: sample)
        }
    }

    @Test("a symlinked config is written through, not replaced")
    func symlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sshconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appending(path: "dotfiles-config")
        let link = directory.appending(path: "config")
        try sample.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        var document = SSHConfigDocument(text: sample)
        try document.remove(alias: "pi")
        try document.save(to: link, original: sample)

        let kind = try FileManager.default.attributesOfItem(atPath: link.path)[.type]
        #expect(kind as? FileAttributeType == .typeSymbolicLink)
        #expect(try String(contentsOf: real, encoding: .utf8) == document.text)
    }

    private func temporaryConfig(_ data: Data) throws -> (URL, cleanUp: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sshconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "config")
        try data.write(to: url)
        return (url, { try? FileManager.default.removeItem(at: directory) })
    }

    @Test("a file that is not UTF-8 is never taken for an empty one and written over")
    func notText() throws {
        let latin1 = Data("# caf".utf8) + Data([0xE9]) + Data("\nHost pi\n".utf8)
        let (url, cleanUp) = try temporaryConfig(latin1)
        defer { cleanUp() }

        #expect(throws: SSHConfigDocument.ReadError.self) { try SSHConfigDocument.read(url) }
        var document = SSHConfigDocument(text: "")
        try document.save(.init(alias: "new", hostName: "n.example"), replacing: nil)
        #expect(throws: SSHConfigDocument.ReadError.self) { try document.save(to: url, original: "") }
        #expect(try Data(contentsOf: url) == latin1)
    }

    @Test("a missing file reads as empty")
    func missing() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID().uuidString)")
        #expect(try SSHConfigDocument.read(url) == "")
    }

    @Test("the backup is the file from before the first save, not the one before the last")
    func backupKeepsTheOriginal() throws {
        let (url, cleanUp) = try temporaryConfig(Data(sample.utf8))
        defer { cleanUp() }

        var document = SSHConfigDocument(text: sample)
        try document.remove(alias: "pi")
        try document.save(to: url, original: sample)
        let once = document.text
        try document.save(.init(alias: "new", hostName: "n.example"), replacing: nil)
        try document.save(to: url, original: once)

        #expect(try String(contentsOf: url.appendingPathExtension("termther-backup"),
                           encoding: .utf8) == sample)
    }

    @Test("a Windows file is read without its carriage returns and keeps them where it is edited")
    func crlf() throws {
        let original = "Host web\r\n    HostName 1.2.3.4\r\n    User me\r\n"
        var document = SSHConfigDocument(text: original)
        #expect(document.entries == [.init(alias: "web", hostName: "1.2.3.4", user: "me")])
        #expect(SSHConfig.parse(original).first?.address == "1.2.3.4")

        try document.save(.init(alias: "web", hostName: "5.6.7.8", user: "me", port: "2222"),
                          replacing: "web")
        try document.save(.init(alias: "db", hostName: "db.example"), replacing: nil)
        #expect(document.text == [
            "Host web", "    HostName 5.6.7.8", "    User me", "    Port 2222", "",
            "Host db", "    HostName db.example", "",
        ].joined(separator: "\r\n"))
    }

    @Test("removing a host keeps a comment that heads the file and takes its tags line")
    func removeKeepsNeighbours() throws {
        var document = SSHConfigDocument(text: """
        # my servers
        Host a
            HostName a.example
        # tags: web
        Host b
            HostName b.example
        """)
        try document.remove(alias: "a")
        #expect(document.text == """
        # my servers
        Host b
            HostName b.example
        """)
    }

    /// A host with every option the editor shows, and two it does not.
    let optioned = """
    Host build
        HostName build.example
        # keep the agent for git
        ForwardAgent yes
        ServerAliveInterval 30
        Compression no
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
        RemoteCommand tmux new -A -s main
        RequestTTY force
        LogLevel QUIET
        SetEnv LANG=C
        # tags: ci

    Host after
        User me

    """

    @Test("the common options and the other lines are read, and come back as they went in")
    func options() throws {
        var document = SSHConfigDocument(text: optioned)
        let build = try #require(document.entries.first)
        #expect(build == .init(alias: "build", hostName: "build.example", forwardAgent: "yes",
                               serverAliveInterval: "30", compression: "no", identitiesOnly: "yes",
                               strictHostKeyChecking: "accept-new",
                               remoteCommand: "tmux new -A -s main", requestTTY: "force",
                               other: ["LogLevel QUIET", "SetEnv LANG=C"]))
        try document.save(build, replacing: "build")
        #expect(document.text == optioned)

        var edited = build
        edited.forwardAgent = ""
        edited.serverAliveInterval = "60"
        edited.requestTTY = ""
        edited.identitiesOnly = ""
        try document.save(edited, replacing: "build")
        #expect(document.text == optioned.replacingOccurrences(of: """
            # keep the agent for git
            ForwardAgent yes
            ServerAliveInterval 30
            Compression no
            IdentitiesOnly yes
            StrictHostKeyChecking accept-new
            RemoteCommand tmux new -A -s main
            RequestTTY force
        """, with: """
            # keep the agent for git
            ServerAliveInterval 60
            Compression no
            StrictHostKeyChecking accept-new
            RemoteCommand tmux new -A -s main
        """))
    }

    @Test("changed other lines replace exactly the old ones, where the first of them was")
    func otherLines() throws {
        var document = SSHConfigDocument(text: optioned)
        var build = try #require(document.entries.first)
        build.other = ["LogLevel DEBUG", "ControlMaster auto", "ControlPath ~/.ssh/cm-%C"]
        try document.save(build, replacing: "build")
        #expect(document.text == optioned.replacingOccurrences(of: """
            LogLevel QUIET
            SetEnv LANG=C
        """, with: """
            LogLevel DEBUG
            ControlMaster auto
            ControlPath ~/.ssh/cm-%C
        """))

        build.other = []
        try document.save(build, replacing: "build")
        #expect(document.text == optioned.replacingOccurrences(of: """
            LogLevel QUIET
            SetEnv LANG=C

        """, with: ""))

        // A new host writes its other lines after its fields.
        try document.save(.init(alias: "fresh", user: "me", other: ["LogLevel QUIET"]), replacing: nil)
        #expect(document.text.hasSuffix("""
        Host fresh
            User me
            LogLevel QUIET

        """))
    }

    @Test("writing a server leaves the host's options and other lines as they are")
    func serverLeavesOptions() throws {
        var document = SSHConfigDocument(text: optioned)
        var server = Server(name: "build", host: "build.example", username: NSUserName())
        server.port = 2222
        try document.write(server, previousAlias: nil, jumpAlias: nil, serverAliases: ["build"])
        #expect(document.text == optioned.replacingOccurrences(of: """
            SetEnv LANG=C
        """, with: """
            SetEnv LANG=C
            Port 2222
        """))
    }

    @Test("only a host holding nothing but a server's fields counts as the app's to remove")
    func ownFields() {
        let document = SSHConfigDocument(text: """
        Host plain
            HostName p.example
            Port 2222
            # tags: lab
        Host keyed
            HostName k.example
            IdentityFile ~/.ssh/k
        Host noted
            # the printer, do not touch
            HostName n.example
        """)
        #expect(document.holdsOnlyServerFields(alias: "plain"))
        #expect(!document.holdsOnlyServerFields(alias: "keyed"))
        #expect(!document.holdsOnlyServerFields(alias: "noted"))
        #expect(!document.holdsOnlyServerFields(alias: "absent"))
    }
}
