import Foundation
import os

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
                       "Base directory for this skill", "<turn_aborted>",
                       // A background task's report and an image's
                       // size note, both written as the user's turn.
                       "<task-notification", "[Image:"]

    // MARK: - listing

    /// Every session of a tool, newest first.
    ///
    /// Token totals need every usage line of every file, so a transcript is
    /// read whole; but only once while its size and date stay put, and
    /// side by side with the others.
    public static func list(_ paths: AgentPaths) -> [AgentSession] {
        let names = paths.tool == .codex ? codexTitles(paths) : [:]
        let files = files(paths)
        // Into slots in the files' order, so the sort below meets them as
        // it always has and ties fall the same way.
        var found = [AgentSession?](repeating: nil, count: files.count)
        found.withUnsafeMutableBufferPointer { buffer in
            // Each iteration writes its own slot and no other.
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: files.count) { index in
                slots[index] = session(at: files[index], tool: paths.tool, names: names)
            }
        }
        forget(allBut: files, under: paths.sessions)
        return found.compactMap { $0 }.sorted { $0.modified > $1.modified }.superseding()
    }

    private static func session(at file: URL, tool: AgentTool, names: [String: String]) -> AgentSession? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        else { return nil }
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let size = attributes[.size] as? Int ?? 0
        let scan = summary(of: file, tool: tool, size: size, modified: modified)
        let id = sessionID(of: file)
        // Codex names its sessions in its index, Claude Code in the file
        // itself; the first message stands in for either.
        let name = names[id].flatMap { $0.isEmpty ? nil : $0 } ?? scan.name ?? scan.title
        return AgentSession(
            tool: tool, id: id, path: file,
            title: clean(name.isEmpty ? "\u{2014}" : name, limit: 200),
            cwd: scan.cwd, modified: modified, size: size, tokens: scan.tokens,
            untitled: scan.title.isEmpty && scan.name == nil,
            messageIDs: scan.messageIDs)
    }

    // MARK: - what a file says

    /// What one transcript says about itself, for its row.
    struct Summary: Sendable {
        var title = ""
        var name: String?
        var cwd = ""
        var tokens = TokenUsage()
        var messageIDs: [String] = []
    }

    /// Summaries by path, with the size and date they were read at: only
    /// the session in progress changes, so a list read again reads that one.
    private static let summaries = OSAllocatedUnfairLock<[String: (size: Int, modified: Date, summary: Summary)]>(
        initialState: [:])

    private static func summary(of file: URL, tool: AgentTool, size: Int, modified: Date) -> Summary {
        if let kept = summaries.withLock({ $0[file.path] }), kept.size == size, kept.modified == modified {
            return kept.summary
        }
        let summary = scan(file, tool: tool)
        summaries.withLock { $0[file.path] = (size, modified, summary) }
        return summary
    }

    /// Drops what was kept for files under `directory` that are gone.
    private static func forget(allBut files: [URL], under directory: URL) {
        let kept = Set(files.map(\.path))
        let prefix = directory.path + "/"
        summaries.withLock { cache in
            cache = cache.filter { !$0.key.hasPrefix(prefix) || kept.contains($0.key) }
        }
    }

    /// The conversation, cleaned for a preview: the user's and the
    /// assistant's turns from the last 600 lines -- where a long session
    /// is now, not where it began -- each cut to 600 characters,
    /// boilerplate left out.
    public static func transcript(of session: AgentSession) -> [(role: String, text: String)] {
        guard let data = try? Data(contentsOf: session.path, options: .mappedIfSafe) else { return [] }
        var out: [(role: String, text: String)] = []
        objects(in: data, limit: 600, fromEnd: true) { object in
            for (role, text) in turns(in: object) where role != "cwd" {
                let cleaned = clean(text, limit: 600)
                if !cleaned.isEmpty { out.append((role, cleaned)) }
            }
            return true
        }
        return out
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
                    && !isSubagent($0)
            }
        }
    }

    /// Whether a Codex session is one Codex opened for itself -- a guardian
    /// reviewing a risky action, a sub-agent -- rather than the user. Its
    /// first line says so, naming the thread it serves; there is nothing in
    /// it to resume, and a busy session leaves dozens of them.
    static func isSubagent(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        // The first line only, which carries the instructions too and can
        // run long: read until its newline, in pieces.
        var line = Data()
        while line.count < 1_048_576, let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if let end = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                line.append(chunk[..<end])
                break
            }
            line.append(chunk)
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta",
              let meta = object["payload"] as? [String: Any] else { return false }
        if let parent = meta["parent_thread_id"] as? String, !parent.isEmpty { return true }
        return (meta["source"] as? [String: Any])?["subagent"] != nil
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

    /// The lines of a file as JSON objects, in order, with garbage skipped,
    /// until `body` returns false: the first `limit` lines and then the
    /// rest as one more piece, or the last `limit` that are not empty.
    private static func objects(in data: Data, limit: Int, fromEnd: Bool = false,
                                _ body: ([String: Any]) -> Bool) {
        data.withUnsafeBytes { bytes in
            func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }
            if fromEnd {
                for line in lastLines(of: bytes, limit: limit) {
                    if let object = object(line), !body(object) { return }
                }
            } else {
                forEachLine(of: bytes, maxSplits: limit) { line in
                    guard let object = object(line) else { return true }
                    return body(object)
                }
            }
        }
    }

    /// The user's and the assistant's turns in one line as (role, text),
    /// with a ("cwd", path) first when it names the working directory, as
    /// both tools write them.
    static func turns(in object: [String: Any]) -> [(role: String, text: String)] {
        var out: [(role: String, text: String)] = []
        let payload = object["payload"] as? [String: Any] ?? object
        if let cwd = (payload["cwd"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
            ?? object["cwd"] as? String {
            out.append(("cwd", cwd))
        }
        let message = object["message"] as? [String: Any] ?? payload
        guard let role = message["role"] as? String, role == "user" || role == "assistant" else { return out }
        var content = message["content"]
        if let blocks = content as? [Any] {
            content = blocks.compactMap { ($0 as? [String: Any]).map { $0["text"] as? String ?? "" } }
                .joined(separator: " ")
        }
        if let text = content as? String, !text.allSatisfy(\.isWhitespace) {
            out.append((role, text))
        }
        return out
    }

    /// One read for the list row: title and directory from the first lines,
    /// tokens and message ids from the whole file.
    private static func scan(_ file: URL, tool: AgentTool) -> Summary {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return Summary() }
        var title: String?
        var cwd: String?
        // Only the first of each is wanted, so the lines stop once both are.
        objects(in: data, limit: 600) { object in
            for (role, text) in turns(in: object) {
                if role == "cwd" {
                    if cwd == nil { cwd = text }
                } else if role == "user", title == nil {
                    let cleaned = clean(text)
                    if !cleaned.isEmpty { title = cleaned }
                }
            }
            return title == nil || cwd == nil
        }
        let pass = tokensAndName(in: data, tool: tool)
        return Summary(title: title ?? "", name: pass.name, cwd: cwd ?? "",
                       tokens: pass.tokens, messageIDs: pass.messageIDs)
    }

    /// Claude Code writes a response's usage on every line of that response
    /// -- its thinking, its text and each tool call -- so the lines of one
    /// request are counted once. Codex writes a running total, and the last
    /// one is the session's.
    ///
    /// The same pass picks up Claude Code's own title for the session
    /// (`ai-title` lines; the last one is current), which the file holds
    /// rather than an index, and the uuid of each message. A line is decoded
    /// only when it holds one of the keys wanted, and then once.
    static func tokensAndName(in data: Data, tool: AgentTool)
        -> (tokens: TokenUsage, name: String?, messageIDs: [String]) {
        var total = TokenUsage()
        var counted = Set<String>()
        var last: Data?
        var name: String?
        var ids: [String] = []
        let decoder = JSONDecoder()
        data.withUnsafeBytes { bytes in
            forEachLine(of: bytes) { line in
                guard !line.isEmpty else { return true }
                if tool == .codex {
                    if line.contains("token_count") { last = Data(line) }
                    return true
                }
                let hasTitle = line.contains("\"aiTitle\"")
                let hasParent = line.contains("\"parentUuid\"")
                let hasUsage = line.contains("\"usage\"")
                guard hasTitle || hasParent || hasUsage,
                      let entry = try? decoder.decode(ClaudeLine.self, from: Data(
                        bytesNoCopy: UnsafeMutableRawPointer(mutating: line.baseAddress!),
                        count: line.count, deallocator: .none))
                else { return true }
                if hasTitle, let title = entry.aiTitle, !title.isEmpty {
                    name = title
                    return true
                }
                if hasParent, entry.type == "user" || entry.type == "assistant", let uuid = entry.uuid {
                    ids.append(uuid)
                }
                guard hasUsage, entry.type == "assistant", let usage = entry.usage else { return true }
                if let request = entry.requestId, !counted.insert(request).inserted { return true }
                total = total + usage
                return true
            }
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

    /// The few fields of a Claude Code line the list reads, each on its own:
    /// one of an unexpected type is missing, as `as?` would have it, rather
    /// than the line being dropped.
    private struct ClaudeLine: Decodable {
        var type: String?
        var uuid: String?
        var requestId: String?
        var aiTitle: String?
        /// Only from a `message.usage` object.
        var usage: TokenUsage?

        private enum Key: String, CodingKey {
            case type, uuid, requestId, aiTitle, message, usage
            case input = "input_tokens", output = "output_tokens"
            case cacheRead = "cache_read_input_tokens", cacheWrite = "cache_creation_input_tokens"
        }

        init(from decoder: Decoder) throws {
            let line = try decoder.container(keyedBy: Key.self)
            type = try? line.decodeIfPresent(String.self, forKey: .type)
            uuid = try? line.decodeIfPresent(String.self, forKey: .uuid)
            requestId = try? line.decodeIfPresent(String.self, forKey: .requestId)
            aiTitle = try? line.decodeIfPresent(String.self, forKey: .aiTitle)
            guard let message = try? line.nestedContainer(keyedBy: Key.self, forKey: .message),
                  let counts = try? message.nestedContainer(keyedBy: Key.self, forKey: .usage) else { return }
            func count(_ key: Key) -> Int { (try? counts.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
            usage = TokenUsage(input: count(.input), output: count(.output),
                               cacheRead: count(.cacheRead), cacheWrite: count(.cacheWrite))
        }
    }

    // MARK: - lines

    /// Each piece of `bytes` between newlines, front to back, until `body`
    /// returns false -- empty ones included, as `split` would with
    /// `omittingEmptySubsequences: false`: after `maxSplits` newlines the
    /// rest is one piece.
    private static func forEachLine(of bytes: UnsafeRawBufferPointer, maxSplits: Int = .max,
                                    _ body: (UnsafeRawBufferPointer) -> Bool) {
        guard let base = bytes.baseAddress else { return }
        var start = 0
        var splits = 0
        while splits < maxSplits, let newline = memchr(base + start, 0x0A, bytes.count - start) {
            let end = base.distance(to: UnsafeRawPointer(newline))
            guard body(UnsafeRawBufferPointer(rebasing: bytes[start..<end])) else { return }
            start = end + 1
            splits += 1
        }
        _ = body(UnsafeRawBufferPointer(rebasing: bytes[start...]))
    }

    /// The last `limit` lines of `bytes` that are not empty, in order.
    private static func lastLines(of bytes: UnsafeRawBufferPointer, limit: Int) -> [UnsafeRawBufferPointer] {
        var lines: [UnsafeRawBufferPointer] = []
        var end = bytes.count
        var index = bytes.count
        while lines.count < limit, index > 0 {
            index -= 1
            guard bytes[index] == 0x0A else { continue }
            if index + 1 < end { lines.append(UnsafeRawBufferPointer(rebasing: bytes[(index + 1)..<end])) }
            end = index
        }
        if lines.count < limit, index == 0, end > 0 { lines.append(UnsafeRawBufferPointer(rebasing: bytes[0..<end])) }
        return lines.reversed()
    }
}

private extension UnsafeRawBufferPointer {
    func contains(_ marker: StaticString) -> Bool {
        guard let base = baseAddress, count >= marker.utf8CodeUnitCount else { return false }
        return memmem(base, count, marker.utf8Start, marker.utf8CodeUnitCount) != nil
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
