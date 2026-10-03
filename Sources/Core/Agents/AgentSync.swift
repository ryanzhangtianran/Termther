import Foundation

/// A tool's setup on this Mac, recreated on a server over SSH.
///
/// The user runs the same agent there and wants the same settings, prompt
/// and skills. What goes is the tool's files as they are here, whole: on
/// the server they are the profile. Claude Code's MCP servers go too,
/// into the `mcpServers` key of the remote `~/.claude.json` and nothing
/// else of it. Plugins do not: those are installed with the tool's own
/// commands, on each machine.
///
/// Everything travels inside one `sh` script, base64-encoded, so no file's
/// content ever meets the shell's quoting.
public enum AgentSync {
    public enum Failure: Error, CustomStringConvertible {
        case tar(Int32)

        public var description: String {
            switch self {
            case .tar(let status): "tar could not pack the skills (exit \(status))."
            }
        }
    }

    /// The marker the script prints last, so a run that stopped short can be
    /// told from one that finished.
    public static let doneMarker = "TERMTHER_SYNC_DONE"

    /// What `script` would send, one line each.
    public static func items(for paths: AgentPaths) throws -> [String] {
        try parts(for: paths).map(\.item)
    }

    /// A POSIX `sh` script that recreates the setup under `$HOME` on the
    /// server, prints a line per thing written, and ends with `doneMarker`.
    public static func script(for paths: AgentPaths) throws -> String {
        let directory = remote(paths.directory, in: paths)
        return """
        set -e
        umask 077
        mkdir -p \(directory) && chmod 700 \(directory)
        \(try parts(for: paths).map(\.shell).joined(separator: "\n"))
        echo \(doneMarker)

        """
    }

    /// The script as `exec` can carry it, one command per entry, in order.
    ///
    /// `sh -c` takes the script as one argument, which Linux caps at 128 KB
    /// and a skills tarball can pass. So it goes over base64-encoded in
    /// pieces, each appended to a file under the home directory, and the
    /// last command decodes and runs it. Each piece is wrapped in `sh -c`
    /// itself, so the login shell's own syntax never matters.
    public static func commands(running script: String) -> [String] {
        let file = "\"$HOME/.termther-sync\""
        let encoded = Array(Data(script.utf8).base64EncodedString().utf8)
        var commands = stride(from: 0, to: encoded.count, by: 96_000).map { start in
            let piece = String(decoding: encoded[start..<min(start + 96_000, encoded.count)], as: UTF8.self)
            return "sh -c " + shellQuoted("printf %s '\(piece)' \(start == 0 ? ">" : ">>") \(file)")
        }
        commands.append("sh -c " + shellQuoted(
            "base64 -d < \(file) > \(file).sh && sh \(file).sh; rc=$?; rm -f \(file) \(file).sh; exit $rc"))
        return commands
    }

    // MARK: - what goes

    /// Each thing the script writes: a line for the page, and the shell that
    /// writes it.
    private static func parts(for paths: AgentPaths) throws -> [(item: String, shell: String)] {
        let manager = FileManager.default
        var parts: [(item: String, shell: String)] = []
        for name in paths.profileFiles {
            let file = paths.directory.appending(path: name)
            guard manager.fileExists(atPath: file.path) else { continue }
            parts.append((item: name == "auth.json" ? "auth.json, with its key" : name,
                          shell: write(try Data(contentsOf: file), to: remote(file, in: paths))))
        }
        if paths.tool == .claude,
           let servers = try JSONFile.read(paths.mcpConfig)["mcpServers"] as? [String: Any], !servers.isEmpty {
            parts.append((item: "MCP servers (\(servers.count)) into ~/.claude.json",
                          shell: try mergeMCP(servers, into: remote(paths.mcpConfig, in: paths))))
        }
        if manager.fileExists(atPath: paths.prompt.path) {
            parts.append((item: paths.prompt.lastPathComponent,
                          shell: write(try Data(contentsOf: paths.prompt), to: remote(paths.prompt, in: paths))))
        }
        let skills = AgentSkill.list(paths).filter(\.isOwn)
        if !skills.isEmpty {
            // Each skill's place under skills/, since a skill may sit at any
            // depth there. Symlinks resolved on both, as in `AgentSkill`.
            let root = paths.skills.resolvingSymlinksInPath().pathComponents.count
            let places = skills.map {
                $0.path.resolvingSymlinksInPath().pathComponents.dropFirst(root).joined(separator: "/")
            }
            let archive = try tarball(of: places, in: paths.skills).base64EncodedString()
            let directory = remote(paths.skills, in: paths)
            parts.append((
                item: "Skills: " + skills.map(\.name).joined(separator: ", "),
                shell: """
                mkdir -p \(directory) && chmod 700 \(directory)
                (cd \(directory) && rm -rf \(places.map(shellQuoted).joined(separator: " ")) \
                && printf %s '\(archive)' | base64 -d | tar -xzf -)
                echo "wrote \(directory.dropFirst().dropLast()): \(places.joined(separator: " "))"
                """))
        }
        return parts
    }

    /// A local path as the script names it: the same place under `$HOME`,
    /// double-quoted.
    private static func remote(_ url: URL, in paths: AgentPaths) -> String {
        "\"$HOME/" + url.path.dropFirst(paths.home.path.count + 1) + "\""
    }

    /// `data` into the file at `path`, readable by its owner alone.
    private static func write(_ data: Data, to path: String) -> String {
        """
        printf %s '\(data.base64EncodedString())' | base64 -d > \(path) && chmod 600 \(path)
        echo "wrote \(path.dropFirst().dropLast())"
        """
    }

    /// `servers` as the `mcpServers` key of the JSON file at `path`, the
    /// other keys kept. Nothing a server is sure to have edits JSON in
    /// place, so python3 does it when it is there; when it is not, or
    /// there is no file yet, the file is written afresh with just the
    /// servers. Simple on purpose: the rest of `~/.claude.json` is the
    /// tool's own record of the machine, and little is lost.
    private static func mergeMCP(_ servers: [String: Any], into path: String) throws -> String {
        let data = try JSONFile.data(["mcpServers": servers])
        return """
        printf %s '\(data.base64EncodedString())' | base64 -d > \(path).termther-tmp
        if [ -s \(path) ] && command -v python3 >/dev/null 2>&1; then
        python3 - \(path) <<'TERMTHER_EOF'
        import json, sys
        path = sys.argv[1]
        with open(path) as f: config = json.load(f)
        with open(path + ".termther-tmp") as f: config.update(json.load(f))
        with open(path + ".termther-tmp", "w") as f: json.dump(config, f, indent=2)
        TERMTHER_EOF
        fi
        mv \(path).termther-tmp \(path) && chmod 600 \(path)
        echo "wrote \(path.dropFirst().dropLast())"
        """
    }

    /// `places` under `root`, as a gzipped tar, as the remote `tar -xzf -`
    /// reads it.
    private static func tarball(of places: [String], in root: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", "-", "-C", root.path] + places
        // Or macOS tar packs a `._` file of extended attributes beside every
        // file, which a Linux tar unpacks as one more file.
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read to the end before waiting, or a large archive fills the pipe
        // and tar never exits.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.tar(process.terminationStatus) }
        return data
    }
}
