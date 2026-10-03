import Foundation

/// Makes and reads SSH key pairs.
///
/// Generation goes through the system `ssh-keygen` rather than a library.
/// It is present on every Mac, it is what produced every key the user already
/// has, and its output is exactly what a server's `authorized_keys` expects --
/// so a key made here is indistinguishable from one made by hand.
public enum SSHKeys {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        case ed25519
        case rsa
        case ecdsa

        public var title: String {
            switch self {
            case .ed25519: "Ed25519"
            case .rsa: "RSA 4096"
            case .ecdsa: "ECDSA P-256"
            }
        }

        /// Ed25519 first: small, fast, and accepted everywhere that is not
        /// running something a decade old.
        var arguments: [String] {
            switch self {
            case .ed25519: ["-t", "ed25519"]
            case .rsa: ["-t", "rsa", "-b", "4096"]
            case .ecdsa: ["-t", "ecdsa", "-b", "256"]
            }
        }
    }

    public struct Pair: Sendable, Identifiable {
        /// The path is unique per key, which is all a sheet needs.
        public var id: String { publicKeyPath }

        public var kind: Kind
        public var privateKey: String
        public var publicKey: String
        /// Where the public half was written, for the user to copy from.
        public var publicKeyPath: String
    }

    public enum Failure: Error, CustomStringConvertible {
        case keygen(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .keygen(let m): "ssh-keygen failed: \(m)"
            case .unreadable(let m): "cannot read the key: \(m)"
            }
        }
    }

    /// The file a generated key is written to, when that name is free.
    /// Public so a caller can show it, and refuse a name that is taken.
    public static func fileName(kind: Kind, name: String) -> String {
        "termther_\(sanitized(name))_\(kind.rawValue)"
    }

    public static let sshDirectory = URL.homeDirectory.appending(path: ".ssh", directoryHint: .isDirectory)

    /// Generates a pair, writing it into `directory` -- `~/.ssh` unless the
    /// app says otherwise.
    ///
    /// The private half also goes into the vault; the file exists so the key
    /// works with `ssh` and `scp` on the command line too, which is what makes
    /// a generated key useful outside this app.
    public static func generate(kind: Kind, name: String, comment: String,
                                in directory: URL = sshDirectory) async throws -> Pair {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        // A taken name gets a number rather than being replaced: the key there
        // may be installed on servers, and nothing else holds a copy of it.
        let base = fileName(kind: kind, name: name)
        func taken(_ stem: String) -> Bool {
            [stem, "\(stem).pub"].contains {
                FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
            }
        }
        var stem = base
        var number = 1
        while taken(stem) {
            number += 1
            stem = "\(base)-\(number)"
        }
        let privateURL = directory.appending(path: stem)
        let publicURL = directory.appending(path: "\(stem).pub")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = kind.arguments + [
            "-q",
            "-N", "",              // no passphrase: the vault is the passphrase
            "-C", comment,
            "-f", privateURL.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.keygen(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: privateURL.path)

        return Pair(
            kind: kind,
            privateKey: try String(contentsOf: privateURL, encoding: .utf8),
            publicKey: try String(contentsOf: publicURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            publicKeyPath: publicURL.path)
    }

    /// A public key file: `type base64 comment`, and where it and its private
    /// half live.
    public struct PublicKey: Sendable, Identifiable, Equatable {
        public var id: String { path }
        public var path: String
        /// The file name without `.pub`, which is how people name keys.
        public var name: String
        /// The whole line, for copying and for installing on a server.
        public var text: String
        /// The private half beside it, when there is one.
        public var privateKeyPath: String?

        /// Reads one line of a `.pub` file; nil when it is not a public key.
        public static func parse(_ contents: String, path: String) -> PublicKey? {
            let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count >= 2, fields[0].hasPrefix("ssh-") || fields[0].hasPrefix("ecdsa-")
                || fields[0].hasPrefix("sk-")
            else { return nil }
            let url = URL(fileURLWithPath: path)
            let privatePath = url.deletingPathExtension().path
            return PublicKey(path: path, name: url.deletingPathExtension().lastPathComponent, text: line,
                             privateKeyPath: FileManager.default.fileExists(atPath: privatePath)
                                ? privatePath : nil)
        }
    }

    /// The public keys in a directory, by name.
    public static func publicKeys(in directory: URL = sshDirectory) -> [PublicKey] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".pub") }
            .compactMap { name -> PublicKey? in
                let path = directory.appending(path: name).path
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8)
                else { return nil }
                return PublicKey.parse(contents, path: path)
            }
            .sorted { $0.name < $1.name }
    }

    /// Removes a key pair: the public half, and the private one beside it
    /// when there is one.
    public static func remove(_ key: PublicKey) throws {
        try FileManager.default.removeItem(atPath: key.path)
        if let privatePath = key.privateKeyPath { try FileManager.default.removeItem(atPath: privatePath) }
    }

    /// Reads a private key from disk, for importing one that already exists.
    public static func read(at url: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        guard text.contains("PRIVATE KEY") else {
            throw Failure.unreadable("\(url.lastPathComponent) is not a private key")
        }
        return text
    }

    /// The private keys already in a directory, for offering them instead of
    /// making the user find the file.
    public static func discover(in directory: URL = sshDirectory) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { !$0.hasSuffix(".pub") && !$0.hasPrefix("known_hosts") && $0 != "config" }
            .map { directory.appending(path: $0) }
            .filter { (try? read(at: $0)) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The script that puts a public key into a server's `authorized_keys`.
    ///
    /// Written to be safe to run twice: `grep -qxF` means a key already there
    /// is not appended again, so a retry after a dropped connection does not
    /// leave duplicates. `umask 077` covers the files it creates, and the
    /// permissions are set explicitly as well -- sshd ignores an
    /// `authorized_keys` that anyone else can write.
    public static func installScript(publicKey: String,
                                     replacing previous: String? = nil) -> String {
        let key = shellQuoted(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        var dropPrevious = ""
        if let previous, !previous.isEmpty {
            // Rotating a key: the old line goes before the new one is added,
            // through a temporary file because sed in place is not portable.
            // grep says 1 when nothing is left, which is fine, and 2 when it
            // could not read the file -- then the partial copy must not
            // replace it, or every key-based login to the account stops.
            dropPrevious = """
            old=\(shellQuoted(previous.trimmingCharacters(in: .whitespacesAndNewlines)))
            rc=0
            grep -vxF "$old" "$ak" > "$ak.termther-tmp" || rc=$?
            if [ "$rc" -gt 1 ]; then rm -f "$ak.termther-tmp"; exit 1; fi
            mv "$ak.termther-tmp" "$ak"

            """
        }
        return """
        set -e
        umask 077
        ak="$HOME/.ssh/authorized_keys"
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        touch "$ak"
        \(dropPrevious)key=\(key)
        grep -qxF "$key" "$ak" || printf '%s\\n' "$key" >> "$ak"
        chmod 600 "$ak"
        """
    }

    /// The one-liner to paste when the app cannot reach the server itself.
    public static func installCommand(publicKey: String) -> String {
        let key = shellQuoted(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
            + "touch ~/.ssh/authorized_keys && "
            + "grep -qxF \(key) ~/.ssh/authorized_keys || "
            + "echo \(key) >> ~/.ssh/authorized_keys && "
            + "chmod 600 ~/.ssh/authorized_keys"
    }

    private static func sanitized(_ name: String) -> String {
        let allowed = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let joined = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return joined.isEmpty ? "key" : joined
    }
}
