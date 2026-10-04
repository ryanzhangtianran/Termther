import Foundation

/// `~/.ssh/config` as a document that can be edited and written back.
///
/// The file is the user's, and ssh reads it for every connection in every
/// terminal -- not just Termther's. So an edit changes only the lines it has to:
/// a host's own directives are rewritten in place, and everything else --
/// comments, blank lines, `Include`, `Match`, `Host *` defaults, keywords this
/// app does not know -- is kept exactly as it was. The document is its lines,
/// and an untouched document writes back the very text it was read from.
public struct SSHConfigDocument: Sendable, Equatable {
    public private(set) var lines: [String] {
        didSet { blocks = Self.blocks(of: lines) }
    }
    /// The structure of `lines`, worked out again whenever they change
    /// rather than on every question asked of it.
    private var blocks: [Block]

    public init(text: String) {
        lines = text.components(separatedBy: "\n")
        blocks = Self.blocks(of: lines)
    }

    public var text: String { lines.joined(separator: "\n") }

    /// A `Host` block naming one concrete machine -- the kind this app edits.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var alias: String
        public var hostName = ""
        public var user = ""
        public var port = ""
        public var identityFile = ""
        public var proxyJump = ""
        /// The common options, each as written -- `yes`, `30` -- or "" when
        /// the block leaves it to ssh's default.
        public var forwardAgent = ""
        public var serverAliveInterval = ""
        public var compression = ""
        public var identitiesOnly = ""
        public var strictHostKeyChecking = ""
        public var remoteCommand = ""
        public var requestTTY = ""
        /// The block's other directives, `Keyword value` each, in file order;
        /// comments are not among them. Written back where they were.
        public var other: [String] = []

        public init(alias: String, hostName: String = "", user: String = "",
                    port: String = "", identityFile: String = "", proxyJump: String = "",
                    forwardAgent: String = "", serverAliveInterval: String = "",
                    compression: String = "", identitiesOnly: String = "",
                    strictHostKeyChecking: String = "", remoteCommand: String = "",
                    requestTTY: String = "", other: [String] = []) {
            self.alias = alias
            self.hostName = hostName
            self.user = user
            self.port = port
            self.identityFile = identityFile
            self.proxyJump = proxyJump
            self.forwardAgent = forwardAgent
            self.serverAliveInterval = serverAliveInterval
            self.compression = compression
            self.identitiesOnly = identitiesOnly
            self.strictHostKeyChecking = strictHostKeyChecking
            self.remoteCommand = remoteCommand
            self.requestTTY = requestTTY
            self.other = other
        }

        public var id: String { alias }
    }

    public enum EditError: Error, Equatable, CustomStringConvertible {
        case invalidAlias
        case duplicateAlias(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .invalidAlias:
                "A host needs one name, without spaces or wildcards."
            case .duplicateAlias(let alias):
                "There is already a host called \u{201C}\(alias)\u{201D}."
            case .notFound(let alias):
                "\u{201C}\(alias)\u{201D} is no longer in the file."
            }
        }
    }

    // MARK: - reading

    /// The hosts this document can edit, in file order.
    public var entries: [Entry] {
        blocks.compactMap { block in block.editableAlias.map { entry(of: block, alias: $0) } }
    }

    /// Every block that names a machine, by its first name -- `Host web
    /// web.example` included, which `entries` leaves out as uneditable -- with
    /// the tags of a `# tags: a, b` comment inside it. What importing reads.
    ///
    /// A name given twice is read from its first block, as ssh reads it:
    /// taking every block, the last would win, and the app would connect
    /// somewhere other than `ssh` does.
    public var destinations: [(entry: Entry, tags: [String])] {
        var seen = Set<String>()
        return blocks.compactMap { block in
            guard let alias = block.firstAlias, seen.insert(alias).inserted else { return nil }
            let tags = lines[block.header + 1 ..< block.limit].lazy.compactMap(Self.tags).first ?? []
            return (entry(of: block, alias: alias), tags)
        }
    }

    private func entry(of block: Block, alias: String) -> Entry {
        var entry = Entry(alias: alias)
        for index in block.body.map(Array.init) ?? [] {
            guard let (keyword, value) = Self.directive(lines[index]) else { continue }
            guard let field = Field(keyword: keyword) else {
                entry.other.append(lines[index].trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            // The first occurrence wins, as it does for ssh.
            if entry[keyPath: field.path].isEmpty { entry[keyPath: field.path] = value }
        }
        return entry
    }

    /// The blocks left alone -- `Host *`, `Match`, several names on one line --
    /// by their opening line, so they can at least be seen.
    public var otherBlocks: [String] {
        blocks.filter { $0.editableAlias == nil }
            .map { lines[$0.header].trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - editing

    /// Adds `entry`, or updates the host currently called `alias`.
    public mutating func save(_ entry: Entry, replacing alias: String?) throws {
        guard Self.isEditableAlias(entry.alias) else { throw EditError.invalidAlias }
        if entry.alias != alias, entries.contains(where: { $0.alias == entry.alias }) {
            throw EditError.duplicateAlias(entry.alias)
        }
        guard let alias else {
            append(entry)
            return
        }
        guard let block = blocks.first(where: { $0.editableAlias == alias }) else {
            throw EditError.notFound(alias)
        }
        update(block, to: entry)
    }

    /// Removes a host, with its `# tags:` line and the comment heading it.
    ///
    /// A comment counts as the host's only with a blank line above it. One
    /// that starts the file, or follows the block before without a gap, may
    /// head the file or be that block's, and stays.
    public mutating func remove(alias: String) throws {
        guard let block = blocks.first(where: { $0.editableAlias == alias }) else {
            throw EditError.notFound(alias)
        }
        var start = block.header
        var top = start
        while top > 0, Self.isComment(lines[top - 1]) { top -= 1 }
        if top > 0, Self.isBlank(lines[top - 1]) { start = top }
        var end = block.end + 1
        // Left behind, a tags line would fall inside the block before and
        // tag that host on the next import.
        while end < block.limit, Self.tags(in: lines[end]) != nil { end += 1 }
        // One blank line goes too, where there would otherwise be two in a row.
        if end < lines.count, Self.isBlank(lines[end]), start == 0 || Self.isBlank(lines[start - 1]) {
            end += 1
        }
        lines.removeSubrange(start..<end)
    }

    /// Whether the host holds nothing but what `write` puts there -- address,
    /// user, port, jump host and tags -- so removing it loses nothing of the
    /// user's own. False for a host this document cannot edit.
    public func holdsOnlyServerFields(alias: String) -> Bool {
        guard let block = blocks.first(where: { $0.editableAlias == alias }) else { return false }
        return lines[(block.header + 1)..<block.limit].allSatisfy { line in
            if Self.isBlank(line) || Self.tags(in: line) != nil { return true }
            guard let (keyword, _) = Self.directive(line) else { return false }
            return ["hostname", "user", "port", "proxyjump"].contains(keyword)
        }
    }

    // MARK: - servers

    /// The `Host` a server is kept under: its name, as one word ssh will not
    /// read as a pattern.
    public static func alias(forServerNamed name: String) -> String {
        String(name.map { " \t*?!,\"".contains($0) ? "-" : $0 })
    }

    /// Puts a server under its `Host`, renamed from `previousAlias` if given.
    ///
    /// Only what the file can hold goes in: address, user, port, jump host.
    /// A field whose effect already matches is left as written -- an absent
    /// `Port` is 22 -- so a server that did not change rewrites nothing.
    /// `IdentityFile` and the options stay the file's own; a key in the
    /// vault has no path.
    /// `serverAliases` are the hosts that are servers too: a `ProxyJump` to
    /// one of them, when the server now has none, was removed, while one to
    /// anything else is the file's own and kept.
    public mutating func write(_ server: Server, previousAlias: String?, jumpAlias: String?,
                               serverAliases: Set<String>) throws {
        let alias = server.configAlias
        let entries = self.entries
        let existing = entries.first { $0.alias == (previousAlias ?? alias) }
            ?? entries.first { $0.alias == alias }
        // Named on a line with other names, which is left to be edited by hand.
        if existing == nil, destinations.contains(where: { $0.entry.alias == alias }) { return }

        var entry = existing ?? Entry(alias: alias)
        entry.alias = alias
        if (entry.hostName.isEmpty ? alias : entry.hostName) != server.host {
            entry.hostName = server.host
        }
        if (entry.user.isEmpty ? NSUserName() : entry.user) != server.username {
            entry.user = server.username
        }
        if (Int(entry.port) ?? 22) != server.port {
            entry.port = server.port == 22 ? "" : String(server.port)
        }
        if let jumpAlias {
            entry.proxyJump = jumpAlias
        } else if serverAliases.contains(entry.proxyJump) {
            entry.proxyJump = ""
        }
        try save(entry, replacing: existing?.alias)
    }

    private mutating func append(_ entry: Entry) {
        let eol = self.eol
        // Built aside and put back once, so the structure is worked out once.
        var lines = self.lines
        // Keep a trailing newline where the file had one.
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        if let last = lines.last, !Self.isBlank(last) {
            lines.append(eol)
        }
        lines.append("Host \(entry.alias)\(eol)")
        for field in Field.allCases where !entry[keyPath: field.path].isEmpty {
            lines.append("    \(field.line(entry[keyPath: field.path]))\(eol)")
        }
        for line in entry.other { lines.append("    \(line)\(eol)") }
        lines.append("")
        self.lines = lines
    }

    private mutating func update(_ block: Block, to entry: Entry) {
        let eol = self.eol
        var body = block.body.map { Array(lines[$0]) } ?? []
        let indent = body.lazy.compactMap { line -> String? in
            guard Self.directive(line) != nil else { return nil }
            return String(line.prefix { $0 == " " || $0 == "\t" })
        }.first ?? "    "

        for field in Field.allCases {
            let value = entry[keyPath: field.path]
            let existing = body.indices.filter {
                Self.directive(body[$0]).flatMap { Field(keyword: $0.0) } == field
            }
            if let first = existing.first {
                // Only the line ssh reads is rewritten, in its own indentation,
                // and only when its value changed.
                if value.isEmpty {
                    body.remove(at: first)
                } else if Self.directive(body[first])?.1 != value {
                    let lead = body[first].prefix { $0 == " " || $0 == "\t" }
                    body[first] = "\(lead)\(field.line(value))\(eol)"
                }
            } else if !value.isEmpty {
                // After the last directive, ahead of any trailing comment.
                let at = (body.lastIndex { Self.directive($0) != nil } ?? -1) + 1
                body.insert("\(indent)\(field.line(value))\(eol)", at: at)
            }
        }

        // The other directives: left as they are unless changed, and then
        // replaced as a run where the first of them was.
        let others = body.indices.filter {
            Self.directive(body[$0]).map { Field(keyword: $0.0) == nil } ?? false
        }
        if others.map({ body[$0].trimmingCharacters(in: .whitespacesAndNewlines) }) != entry.other {
            let at = others.first ?? (body.lastIndex { Self.directive($0) != nil } ?? -1) + 1
            for index in others.reversed() { body.remove(at: index) }
            body.insert(contentsOf: entry.other.map { "\(indent)\($0)\(eol)" }, at: at)
        }

        let headerLead = lines[block.header].prefix { $0 == " " || $0 == "\t" }
        let header = "\(headerLead)Host \(entry.alias)\(eol)"
        let range = block.header...max(block.header, block.end)
        lines.replaceSubrange(range, with: [header] + body)
    }

    /// What ends a line besides the newline: a file written on Windows keeps
    /// its `\r`, on the lines this app adds as well as its own.
    private var eol: String { lines.contains { $0.hasSuffix("\r") } ? "\r" : "" }

    // MARK: - reading and writing the file

    public enum ReadError: Error, CustomStringConvertible {
        case notText

        public var description: String {
            "~/.ssh/config is not UTF-8 text, so Termther leaves it alone. "
                + "Save it as UTF-8 to sync servers with it."
        }
    }

    /// The file's text, or "" when there is no file yet.
    ///
    /// A file that is there but cannot be read throws rather than coming back
    /// empty: taken for an empty file, it would be written over with only
    /// Termther's hosts.
    public static func read(_ url: URL = SSHConfig.defaultURL) throws -> String {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return "" }
        guard let text = String(data: try Data(contentsOf: target), encoding: .utf8)
        else { throw ReadError.notText }
        return text
    }

    /// Files already copied aside by this run of the app. The copy is the file
    /// as it was before Termther first wrote to it, not as of its last write:
    /// renewed on every save, one sync writing several hosts would leave only
    /// Termther's own changes in it.
    nonisolated(unsafe) private static var backedUp: Set<String> = []
    private static let backupLock = NSLock()

    public enum SaveError: Error, Equatable, CustomStringConvertible {
        case changedOnDisk

        public var description: String {
            "The file was changed by something else since it was opened. "
                + "Reload it and make the change again."
        }
    }

    /// Writes the document back over the file it was read from.
    ///
    /// Refuses when the file no longer holds `original` -- someone else edited
    /// it meanwhile, and writing would silently throw their change away -- or
    /// cannot be read at all. The contents from before this run's first write
    /// are copied beside it, the file's permissions are kept, and a symlink is
    /// written through rather than replaced, since a config kept in a dotfiles
    /// repository is usually a link into it.
    public func save(to url: URL = SSHConfig.defaultURL, original: String) throws {
        let target = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard try Self.read(target) == original else { throw SaveError.changedOnDisk }

        let exists = manager.fileExists(atPath: target.path)
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        if exists {
            try Self.backupLock.withLock {
                guard !Self.backedUp.contains(target.path) else { return }
                let backup = target.appendingPathExtension("termther-backup")
                try? manager.removeItem(at: backup)
                try manager.copyItem(at: target, to: backup)
                Self.backedUp.insert(target.path)
            }
        } else {
            try manager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        try Data(text.utf8).write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: permissions ?? 0o600],
                                  ofItemAtPath: target.path)
    }

    // MARK: - structure

    /// A `Host` or `Match` line, and the lines it governs: up to its last
    /// directive, so comments and blank lines before the next block are not
    /// counted as its own.
    private struct Block: Equatable, Sendable {
        let header: Int
        /// Last line belonging to the block; `header` when it has no body.
        let end: Int
        /// The next block's header, or the end of the file.
        let limit: Int
        /// The single concrete alias, when the block is one this app edits.
        let editableAlias: String?
        /// The first name on a `Host` line, unless it is a pattern.
        let firstAlias: String?
        var body: ClosedRange<Int>? { end > header ? (header + 1)...end : nil }
    }

    private static func blocks(of lines: [String]) -> [Block] {
        let headers = lines.indices.filter {
            guard let keyword = Self.directive(lines[$0])?.0 else { return false }
            return keyword == "host" || keyword == "match"
        }
        return headers.enumerated().map { position, header in
            let limit = position + 1 < headers.count ? headers[position + 1] : lines.count
            let end = (header + 1 ..< limit).last { Self.directive(lines[$0]) != nil } ?? header
            let (keyword, value) = Self.directive(lines[header])!
            let alias = keyword == "host" && Self.isEditableAlias(value) ? value : nil
            let first = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            let firstAlias = keyword == "host" ? first.flatMap { Self.isEditableAlias($0) ? $0 : nil } : nil
            return Block(header: header, end: end, limit: limit,
                         editableAlias: alias, firstAlias: firstAlias)
        }
    }

    /// `Keyword value` or `Keyword=value`, keyword lowercased; nil for blank
    /// lines and comments.
    private static func directive(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" })
        else { return (trimmed.lowercased(), "") }
        let keyword = trimmed[..<split].lowercased()
        let value = trimmed[split...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (keyword, value)
    }

    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The tags of a `# tags: a, b` comment; nil for any other line.
    private static func tags(in line: String) -> [String]? {
        let comment = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard comment.hasPrefix("#") else { return nil }
        let text = comment.dropFirst().trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("tags:") else { return nil }
        return text.dropFirst("tags:".count).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One name, and not a pattern: `Host *` and `Host a b` are rules, left to
    /// be edited by hand.
    private static func isEditableAlias(_ value: String) -> Bool {
        !value.isEmpty && !value.contains { " \t*?!,\"".contains($0) }
    }

    private static func quoted(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }

    /// The directives this document edits, spelled as ssh spells them.
    fileprivate enum Field: String, CaseIterable {
        case hostName = "HostName", user = "User", port = "Port"
        case identityFile = "IdentityFile", proxyJump = "ProxyJump"
        case forwardAgent = "ForwardAgent", serverAliveInterval = "ServerAliveInterval"
        case compression = "Compression", identitiesOnly = "IdentitiesOnly"
        case strictHostKeyChecking = "StrictHostKeyChecking", remoteCommand = "RemoteCommand"
        case requestTTY = "RequestTTY"

        init?(keyword: String) {
            guard let field = Self.allCases.first(where: { $0.rawValue.lowercased() == keyword })
            else { return nil }
            self = field
        }

        /// The directive as written: a value with spaces quoted, except
        /// `RemoteCommand`, whose value is the rest of the line as it is.
        func line(_ value: String) -> String {
            "\(rawValue) \(self == .remoteCommand ? value : SSHConfigDocument.quoted(value))"
        }

        var path: WritableKeyPath<Entry, String> {
            switch self {
            case .hostName:     \.hostName
            case .user:         \.user
            case .port:         \.port
            case .identityFile: \.identityFile
            case .proxyJump:    \.proxyJump
            case .forwardAgent: \.forwardAgent
            case .serverAliveInterval:   \.serverAliveInterval
            case .compression:  \.compression
            case .identitiesOnly:        \.identitiesOnly
            case .strictHostKeyChecking: \.strictHostKeyChecking
            case .remoteCommand:         \.remoteCommand
            case .requestTTY:   \.requestTTY
            }
        }
    }
}

public extension Server {
    /// The `Host` this server is kept under in ~/.ssh/config.
    var configAlias: String { SSHConfigDocument.alias(forServerNamed: displayName) }
}
