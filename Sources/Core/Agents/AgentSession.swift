import Foundation

/// Tokens a session has cost, as the tool counted them.
///
/// The four parts are disjoint, so `total` is honest for both tools: Claude
/// Code reports cached input beside `input_tokens`, and Codex reports it
/// inside, so Codex's cached share is taken back out of `input` here.
public struct TokenUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                   cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}

/// A transcript a tool left behind, and what it says about itself.
///
/// Both tools write one JSON object per line, and neither promises the file
/// is whole: a session that was killed ends mid-line, and the tools' own
/// bookkeeping lines carry no message at all. So a line that does not parse,
/// or is not the shape expected, is skipped rather than failing the session.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public let tool: AgentTool
    /// The session's UUID: the last five dash-separated parts of the file
    /// name, which is the whole stem for Claude Code and the tail after the
    /// timestamp for Codex's `rollout-<timestamp>-<uuid>`.
    public let id: String
    public let path: URL
    /// Codex's own name for the thread when it gave one, else the first user
    /// message that was not the tool's boilerplate, else a dash.
    public let title: String
    public let cwd: String
    public let modified: Date
    /// Bytes on disk.
    public let size: Int
    public let tokens: TokenUsage
    /// Not worth a row: opened and closed without a word (no turn of the
    /// user's, no tokens -- Claude Code leaves one behind for every launch
    /// quit at the prompt), or an earlier copy of a conversation that went
    /// on under another id, which is how Claude Code resumes: the new file
    /// starts with the old one's messages.
    public var isStale: Bool { (untitled && tokens.total == 0) || isSuperseded }
    let untitled: Bool
    var isSuperseded = false
    /// The uuids of the messages, for telling a copy from its continuation.
    let messageIDs: [String]

    /// What to run, in `cwd`, to pick the session up again.
    public var resumeCommand: String {
        switch tool {
        case .claude: "claude --resume \(id)"
        case .codex: "codex resume \(id)"
        }
    }

    /// Lines that are the tool's, not the user's: a session whose first user
    /// line is one of these is titled by the next one.
    static let junk = ["<command-", "<local-command", "<user-prompt", "<environment_context",
                       "<system-reminder", "Caveat:", "The following is the Codex agent history",
                       "Base directory for this skill", "<turn_aborted>"]

    // MARK: - listing

    /// Every session of a tool, newest first.
    // ponytail: token totals need every usage line of every file, so this
    // reads each transcript whole; cache by (path, mtime) if a big history
    // makes the list slow to open.
    public static func list(_ paths: AgentPaths) -> [AgentSession] {
        let names = paths.tool == .codex ? codexTitles(paths) : [:]
        return files(paths).compactMap { file -> AgentSession? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            else { return nil }
            let scan = scan(file, tool: paths.tool)
            let id = sessionID(of: file)
            let pass = tokensAndName(in: file, tool: paths.tool)
            // Codex names its sessions in its index, Claude Code in the file
            // itself; the first message stands in for either.
            let name = names[id].flatMap { $0.isEmpty ? nil : $0 } ?? scan.name ?? scan.title
            return AgentSession(
                tool: paths.tool, id: id, path: file,
                title: clean(name.isEmpty ? "\u{2014}" : name, limit: 200),
                cwd: scan.cwd,
                modified: attributes[.modificationDate] as? Date ?? .distantPast,
                size: attributes[.size] as? Int ?? 0,
                tokens: scan.tokens,
                untitled: scan.title.isEmpty && scan.name == nil,
                messageIDs: pass.messageIDs)
        }.sorted { $0.modified > $1.modified }.superseding()
    }

    /// The conversation, cleaned for a preview: the user's and the
    /// assistant's turns from the first 600 lines, each cut to 600
    /// characters, boilerplate left out.
    public static func transcript(of session: AgentSession) -> [(role: String, text: String)] {
        messages(in: session.path).compactMap { role, text in
            guard role != "cwd" else { return nil }
            let cleaned = clean(text, limit: 600)
            return cleaned.isEmpty ? nil : (role, cleaned)
        }
    }

    /// Removes the transcript, and for Codex the lines naming it in the
    /// title index, so a deleted session's name does not linger.
    public static func delete(_ session: AgentSession, paths: AgentPaths) throws {
        try FileManager.default.removeItem(at: session.path)
        guard session.tool == .codex,
              let text = try? String(contentsOf: paths.sessionIndex, encoding: .utf8) else { return }
        let kept = text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.contains(session.id) }
        try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: paths.sessionIndex, options: .atomic)
    }

    // MARK: - files

    /// The transcripts: Claude Code's `projects/<cwd>/<uuid>.jsonl`, and only
    /// those -- the subdirectories beside them hold a session's attachments
    /// -- and Codex's `sessions/yyyy/mm/dd/rollout-*.jsonl`.
    private static func files(_ paths: AgentPaths) -> [URL] {
        let manager = FileManager.default
        switch paths.tool {
        case .claude:
            let projects = (try? manager.contentsOfDirectory(atPath: paths.sessions.path)) ?? []
            return projects.flatMap { project -> [URL] in
                let directory = paths.sessions.appending(path: project, directoryHint: .isDirectory)
                let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
                return names.filter { $0.hasSuffix(".jsonl") }.map { directory.appending(path: $0) }
            }
        case .codex:
            guard let walk = manager.enumerator(at: paths.sessions, includingPropertiesForKeys: nil)
            else { return [] }
            return walk.compactMap { $0 as? URL }.filter {
                $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl"
            }
        }
    }

    static func sessionID(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
            .suffix(5).joined(separator: "-")
    }

    /// Codex's `session_index.jsonl`: thread names by session ID.
    private static func codexTitles(_ paths: AgentPaths) -> [String: String] {
        guard let text = try? String(contentsOf: paths.sessionIndex, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String else { continue }
            names[id] = object["thread_name"] as? String ?? ""
        }
        return names
    }

    // MARK: - reading a transcript

    /// Whitespace collapsed to single spaces and cut to `limit` characters;
    /// "" for a line that is the tool's boilerplate rather than the user's.
    static func clean(_ text: String, limit: Int = 100) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return junk.contains { collapsed.hasPrefix($0) } ? "" : String(collapsed.prefix(limit))
    }

    /// The lines of a file as JSON objects, in order, with garbage skipped.
    /// Only the first `limit` lines are decoded; `tokens` runs its own pass
    /// over the rest.
    private static func objects(in file: URL, limit: Int) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        return data.split(separator: UInt8(ascii: "\n"), maxSplits: limit, omittingEmptySubsequences: false)
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The user's and the assistant's turns as (role, text), with a ("cwd",
    /// path) for every line that names the working directory, as both tools
    /// write them.
    static func messages(in file: URL, limit: Int = 600) -> [(role: String, text: String)] {
        var out: [(role: String, text: String)] = []
        for object in objects(in: file, limit: limit) {
            let payload = object["payload"] as? [String: Any] ?? object
            if let cwd = (payload["cwd"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
                ?? object["cwd"] as? String {
                out.append(("cwd", cwd))
            }
            let message = object["message"] as? [String: Any] ?? payload
            guard let role = message["role"] as? String, role == "user" || role == "assistant"
            else { continue }
            var content = message["content"]
            if let blocks = content as? [Any] {
                content = blocks.compactMap { ($0 as? [String: Any]).map { $0["text"] as? String ?? "" } }
                    .joined(separator: " ")
            }
            if let text = content as? String, !text.allSatisfy(\.isWhitespace) {
                out.append((role, text))
            }
        }
        return out
    }

    /// One pass for the list row: title and directory from the first lines,
    /// tokens from the whole file.
    private static func scan(_ file: URL, tool: AgentTool)
        -> (title: String, name: String?, cwd: String, tokens: TokenUsage) {
        let turns = messages(in: file)
        let (tokens, name, _) = tokensAndName(in: file, tool: tool)
        return (turns.lazy.filter { $0.role == "user" }.map { clean($0.text) }.first { !$0.isEmpty } ?? "",
                name, turns.first { $0.role == "cwd" }?.text ?? "", tokens)
    }

    /// Claude Code writes a response's usage on every line of that response
    /// -- its thinking, its text and each tool call -- so the lines of one
    /// request are counted once. Codex writes a running total, and the last
    /// one is the session's.
    static func tokens(in file: URL, tool: AgentTool) -> TokenUsage { tokensAndName(in: file, tool: tool).tokens }

    /// The same pass also picks up Claude Code's own title for the session
    /// (`ai-title` lines; the last one is current), which the file holds
    /// rather than an index, and the uuid of each message.
    static func tokensAndName(in file: URL, tool: AgentTool)
        -> (tokens: TokenUsage, name: String?, messageIDs: [String]) {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return (TokenUsage(), nil, []) }
        let marker = Data((tool == .claude ? "\"usage\"" : "token_count").utf8)
        let titleMarker = Data("\"aiTitle\"".utf8)
        let messageMarker = Data("\"parentUuid\"".utf8)
        var total = TokenUsage()
        var counted = Set<String>()
        var last: Data?
        var name: String?
        var ids: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if tool == .claude, line.range(of: titleMarker) != nil,
               let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let title = object["aiTitle"] as? String, !title.isEmpty {
                name = title
                continue
            }
            if tool == .claude, line.range(of: messageMarker) != nil,
               let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               ["user", "assistant"].contains(object["type"] as? String ?? ""),
               let uuid = object["uuid"] as? String {
                ids.append(uuid)
            }
            guard line.range(of: marker) != nil else { continue }
            if tool == .codex {
                last = line
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
            else { continue }
            if let request = object["requestId"] as? String, !counted.insert(request).inserted { continue }
            total = total + TokenUsage(
                input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0)
        }
        if let last, let object = try? JSONSerialization.jsonObject(with: last) as? [String: Any],
           let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
           let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] {
            let cached = usage["cached_input_tokens"] as? Int ?? 0
            total = TokenUsage(
                input: (usage["input_tokens"] as? Int ?? 0) - cached,
                output: usage["output_tokens"] as? Int ?? 0, cacheRead: cached,
                cacheWrite: usage["cache_write_input_tokens"] as? Int ?? 0)
        }
        return (total, name, ids)
    }
}

private extension Array where Element == AgentSession {
    /// Marks each earlier copy of a conversation: a session whose messages
    /// another, longer one begins with, which is what resuming leaves.
    func superseding() -> [AgentSession] {
        var byFirst: [String: [Int]] = [:]
        for (index, session) in enumerated() {
            if let first = session.messageIDs.first { byFirst[first, default: []].append(index) }
        }
        var result = self
        for indices in byFirst.values where indices.count > 1 {
            let longest = indices.max { self[$0].messageIDs.count < self[$1].messageIDs.count }!
            let longestIDs = Set(self[longest].messageIDs)
            for index in indices where index != longest
                && self[index].messageIDs.allSatisfy(longestIDs.contains) {
                result[index].isSuperseded = true
            }
        }
        return result
    }
}
