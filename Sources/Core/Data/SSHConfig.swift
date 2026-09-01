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

    /// Parses the subset of the format that describes a destination.
    ///
    /// Keywords are case-insensitive and the first value of a repeated one
    /// wins, both as OpenSSH itself behaves.
    public static func parse(_ text: String) -> [Host] {
        var hosts: [Host] = []
        var current: Host?

        func finish() {
            // A pattern is a rule, not a destination: `Host *` sets defaults
            // for everything and is not somewhere you can connect.
            if let host = current, !host.alias.contains("*"), !host.alias.contains("?") {
                hosts.append(host)
            }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                let comment = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard comment.lowercased().hasPrefix("tags:") else { continue }
                current?.tags = comment.dropFirst("tags:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                continue
            }

            let parts = line.split(separator: " ", maxSplits: 1,
                                   omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t=")) }
            guard parts.count == 2 else { continue }
            let keyword = parts[0].lowercased()
            let value = parts[1]

            if keyword == "host" {
                finish()
                // One line can name several aliases; the first is the one a
                // person would recognise.
                let alias = value.split(separator: " ").first.map(String.init) ?? value
                current = Host(alias: alias, hostName: "", port: 22, user: "")
                continue
            }

            guard current != nil else { continue }
            switch keyword {
            case "hostname":     current?.hostName = value
            case "port":         current?.port = Int(value) ?? 22
            case "user":         current?.user = value
            case "identityfile": current?.identityFile = expand(value)
            case "proxyjump":    current?.proxyJump = value
            default: break
            }
        }
        finish()
        return hosts
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
    @discardableResult
    func importHosts(_ hosts: [SSHConfig.Host],
                     credentials: [String: Int64] = [:]) throws -> Int {
        var savedIDs: [String: Int64] = [:]

        // Two passes: everything is saved first, so a jump host named later in
        // the file can still be linked up.
        for host in hosts {
            var server = Server(name: host.alias, host: host.address, port: host.port,
                                username: host.user.isEmpty ? NSUserName() : host.user,
                                tags: host.tags.joined(separator: ", "))
            server.credentialId = credentials[host.alias]
            server = try save(server)
            if let id = server.id { savedIDs[host.alias] = id }
        }

        for host in hosts {
            guard let jump = host.proxyJump, let jumpID = savedIDs[jump],
                  let id = savedIDs[host.alias], var server = try server(id: id)
            else { continue }
            server.jumpHostId = jumpID
            try save(server)
        }

        return hosts.count
    }
}
