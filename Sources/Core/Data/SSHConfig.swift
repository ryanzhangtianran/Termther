import Foundation

/// Reads `~/.ssh/config`.
///
/// Importing from it beats retyping what is already written down, and it is
/// where most people's servers actually live. Only the directives that map onto
/// a saved server are understood; the rest are ignored rather than guessed at.
public enum SSHConfig {
    public struct Host: Sendable, Equatable, Identifiable {
        public var alias: String
        public var hostName: String
        public var port: Int
        public var user: String
        /// `IdentityFile`, expanded.
        public var identityFile: String?

        /// The key this entry would actually use.
        ///
        /// An entry without an `IdentityFile` is not keyless: ssh falls back to
        /// the standard names in `~/.ssh`, which is how most people's configs
        /// work. Importing without this leaves every such server unable to log
        /// in, reported as having no credential at all.
        public var effectiveIdentityFile: String? {
            if let identityFile,
               FileManager.default.fileExists(atPath: identityFile) {
                return identityFile
            }
            let directory = URL.homeDirectory.appending(path: ".ssh", directoryHint: .isDirectory)
            // The order ssh itself tries them in.
            for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
                let candidate = directory.appending(path: name)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.path
                }
            }
            return nil
        }
        /// `ProxyJump`, which is another alias in the same file.
        public var proxyJump: String?
        /// From a `# tags: a, b` comment inside the block.
        ///
        /// ssh has no notion of tags, but it ignores comments -- so a file
        /// carrying them stays a valid config that `ssh` will still read. For a
        /// hundred machines written out in one go, grouping is the difference
        /// between a list and a wall.
        public var tags: [String] = []

        public var id: String { alias }

        /// What to connect to: `HostName` when given, otherwise the alias is
        /// the address, which is how a one-line entry works.
        public var address: String { hostName.isEmpty ? alias : hostName }
    }

    public static var defaultURL: URL {
        URL.homeDirectory.appending(path: ".ssh/config")
    }

    public static func read(at url: URL = defaultURL) -> [Host] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// The entries that describe a destination, read by `SSHConfigDocument` so
    /// that importing and editing see the same file the same way.
    public static func parse(_ text: String) -> [Host] {
        SSHConfigDocument(text: text).destinations.map { entry, tags in
            Host(alias: entry.alias, hostName: entry.hostName,
                 port: Int(entry.port).flatMap { Connector.isPort($0) ? $0 : nil } ?? 22,
                 user: entry.user,
                 identityFile: entry.identityFile.isEmpty ? nil : expand(entry.identityFile),
                 proxyJump: entry.proxyJump.isEmpty ? nil : entry.proxyJump, tags: tags)
        }
    }

    private static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard trimmed.hasPrefix("~") else { return trimmed }
        return URL.homeDirectory.path + trimmed.dropFirst()
    }
}

public extension Store {
    /// What importing a config entry would do.
    ///
    /// Reported rather than acted on, so the user sees which entries are new
    /// and which they already have before anything is written.
    enum ImportOutcome: Sendable, Equatable {
        case new
        case alreadySaved
    }

    func classify(_ hosts: [SSHConfig.Host]) throws -> [(host: SSHConfig.Host, outcome: ImportOutcome)] {
        let existing = try servers()
        return hosts.map { host in
            let match = existing.contains {
                $0.host == host.address && $0.port == host.port
            }
            return (host, match ? .alreadySaved : .new)
        }
    }

    /// Saves the chosen entries, resolving `ProxyJump` against what was
    /// imported alongside them.
    ///
    /// `credentials` maps an alias to the credential already stored for it.
    /// The store does not build those itself: sealing a key needs the vault,
    /// and keeping that out of here is what stops a plaintext secret ever
    /// reaching the model layer.
    func importHosts(_ hosts: [SSHConfig.Host],
                     credentials: [String: Int64] = [:]) throws {
        var savedIDs: [String: Int64] = [:]

        // Two passes: everything is saved first, so a jump host named later in
        // the file can still be linked up.
        // After whatever is there, in file order.
        let base = try nextSortOrder()
        for (index, host) in hosts.enumerated() {
            var server = Server(name: host.alias, host: host.address, port: host.port,
                                username: host.user.isEmpty ? NSUserName() : host.user,
                                tags: host.tags.joined(separator: ", "), sortOrder: base + index)
            server.credentialID = credentials[host.alias]
            server = try save(server)
            if let id = server.id { savedIDs[host.alias] = id }
        }

        // A jump host already saved counts as well as one in this batch:
        // importing from another file, it is usually one of those.
        let known = try servers()
        for host in hosts {
            guard let jump = host.proxyJump,
                  let jumpID = savedIDs[jump] ?? known.first(where: { $0.configAlias == jump })?.id,
                  let id = savedIDs[host.alias], var server = known.first(where: { $0.id == id })
            else { continue }
            server.jumpHostID = jumpID
            try save(server)
        }
    }
}
