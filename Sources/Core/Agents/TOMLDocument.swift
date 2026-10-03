import Foundation

/// A TOML file as lines that can be edited and written back.
///
/// Codex's `config.toml` is the user's, and Codex itself rewrites it too. So
/// this is the same bargain as `SSHConfigDocument`: an edit touches the line
/// it has to and nothing else. Comments, blank lines, tables this app does not
/// know and values it cannot parse are kept exactly as they were, and an
/// untouched document writes back the very text it was read from.
///
/// It knows enough TOML for what Codex writes: `[a.b]` headers, bare and
/// quoted keys, strings, booleans, numbers and one-line arrays of strings.
/// Anything else is carried as its raw text.
public struct TOMLDocument: Sendable, Equatable {
    private var lines: [String]

    public init(text: String) {
        lines = text.components(separatedBy: "\n")
    }

    public var text: String { lines.joined(separator: "\n") }

    /// A value this document can read and write.
    public enum Value: Equatable, Sendable {
        case string(String)
        case bool(Bool)
        case integer(Int)
        case float(Double)
        case array([Value])
        /// Something more elaborate -- an inline table, a multi-line string --
        /// carried as it was written.
        case raw(String)

        public var string: String? { if case .string(let s) = self { s } else { nil } }
        public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
        public var strings: [String]? {
            if case .array(let items) = self { items.compactMap(\.string) } else { nil }
        }
    }

    // MARK: - reading

    /// The tables under `prefix`, by path, in file order; `[mcp_servers.a]`
    /// under `["mcp_servers"]` is `["mcp_servers", "a"]`.
    public func tables(under prefix: [String]) -> [[String]] {
        headers.map(\.path).filter { $0.count > prefix.count && $0.starts(with: prefix) }
    }

    /// The keys set in the table at `path`, in file order.
    public func keys(in path: [String]) -> [String] {
        guard let range = block(at: path) else { return [] }
        return lines[range].compactMap { Self.keyValue($0)?.0 }
    }

    /// `key` in the table at `path` (`[]` for the top level); nil when absent.
    public func value(_ key: String, in path: [String]) -> Value? {
        guard let range = block(at: path) else { return nil }
        return lines[range].lazy.compactMap { line -> Value? in
            guard let (name, raw) = Self.keyValue(line), name == key else { return nil }
            return Self.parse(raw)
        }.first
    }

    // MARK: - editing

    /// Sets `key` in the table at `path`, or removes it when `value` is nil.
    /// The table is added at the end when it is not there, and a line whose
    /// value is already right is left as written.
    public mutating func set(_ key: String, to value: Value?, in path: [String]) {
        if value == nil, block(at: path) == nil { return }
        let range = block(at: path) ?? addTable(path)
        let existing = range.first { Self.keyValue(lines[$0])?.0 == key }
        guard let value else {
            if let existing { lines.remove(at: existing) }
            return
        }
        if let existing, Self.keyValue(lines[existing]).map({ Self.parse($0.1) }) == value { return }
        let line = "\(Self.key(key)) = \(Self.encode(value))"
        if let existing {
            lines[existing] = line
        } else {
            // After the last key line, ahead of the blank lines before the
            // next table.
            let at = (range.last { Self.keyValue(lines[$0]) != nil } ?? range.lowerBound - 1) + 1
            lines.insert(line, at: at)
        }
    }

    /// The text of the table at `path` and its subtables, as written, for
    /// carrying into another document. Empty when there is none.
    public func text(ofTable path: [String]) -> String {
        headers.filter { $0.path.starts(with: path) }
            .map { lines[$0.line..<$0.limit].joined(separator: "\n").trimmingCharacters(in: .newlines) }
            .joined(separator: "\n\n")
    }

    /// Removes the table at `path` with everything in it, and its subtables.
    public mutating func removeTable(_ path: [String]) {
        for header in headers.reversed() where header.path.starts(with: path) {
            var end = header.limit
            var start = header.line
            // The file keeps its final newline, and one blank line goes with
            // the table where two would otherwise meet.
            if end == lines.count, lines.last == "" { end -= 1 }
            if start > 0, Self.isBlank(lines[start - 1]), end < lines.count, Self.isBlank(lines[end]) {
                start -= 1
            }
            lines.removeSubrange(start..<end)
        }
    }

    /// Appends `[path]` and returns the (empty) range it governs.
    private mutating func addTable(_ path: [String]) -> Range<Int> {
        if lines.last == "" { lines.removeLast() }
        if let last = lines.last, !Self.isBlank(last) { lines.append("") }
        lines.append("[\(path.map(Self.key).joined(separator: "."))]")
        lines.append("")
        return lines.count - 1 ..< lines.count - 1
    }

    // MARK: - structure

    private struct Header {
        let line: Int
        let path: [String]
        /// The next header's line, or the end of the file.
        let limit: Int
    }

    private var headers: [Header] {
        let found = lines.indices.compactMap { index in Self.tablePath(lines[index]).map { (index, $0) } }
        return found.enumerated().map { position, header in
            Header(line: header.0, path: header.1,
                   limit: position + 1 < found.count ? found[position + 1].0 : lines.count)
        }
    }

    /// The lines a table governs, header excluded. The top level runs from the
    /// first line to the first header.
    private func block(at path: [String]) -> Range<Int>? {
        if path.isEmpty { return 0 ..< (headers.first?.line ?? lines.count) }
        guard let header = headers.first(where: { $0.path == path }) else { return nil }
        return header.line + 1 ..< header.limit
    }

    /// The path of a `[a.b."c d"]` line; nil for anything else, `[[arrays]]`
    /// of tables included.
    private static func tablePath(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["),
              let close = trimmed.firstIndex(of: "]") else { return nil }
        return parseKeyPath(String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]))
    }

    /// `key = value` split at the first `=` outside a quoted key; the value is
    /// the raw text after it, comment and all.
    private static func keyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else { return nil }
        var inQuote: Character?
        for index in trimmed.indices {
            let character = trimmed[index]
            if let quote = inQuote {
                if character == quote { inQuote = nil }
            } else if character == "\"" || character == "'" {
                inQuote = character
            } else if character == "=" {
                guard let path = parseKeyPath(String(trimmed[..<index])), path.count == 1
                else { return nil }
                return (path[0], String(trimmed[trimmed.index(after: index)...]))
            }
        }
        return nil
    }

    /// `a.b."c.d"` as its parts; nil when it is not a key.
    private static func parseKeyPath(_ text: String) -> [String]? {
        var parts: [String] = []
        var scanner = Substring(text)
        while true {
            scanner = scanner.drop { $0 == " " || $0 == "\t" }
            if scanner.first == "\"" || scanner.first == "'" {
                guard let (string, rest) = parseString(scanner) else { return nil }
                parts.append(string)
                scanner = rest
            } else {
                let bare = scanner.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                guard !bare.isEmpty else { return nil }
                parts.append(String(bare))
                scanner = scanner.dropFirst(bare.count)
            }
            scanner = scanner.drop { $0 == " " || $0 == "\t" }
            guard scanner.first == "." else { return scanner.isEmpty ? parts : nil }
            scanner = scanner.dropFirst()
        }
    }

    // MARK: - values

    static func parse(_ raw: String) -> Value {
        guard let (value, rest) = parseValue(Substring(raw)) else { return .raw(raw) }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        return tail.isEmpty || tail.hasPrefix("#") ? value : .raw(raw)
    }

    private static func parseValue(_ text: Substring) -> (Value, Substring)? {
        let text = text.drop { $0 == " " || $0 == "\t" }
        guard let first = text.first else { return nil }
        switch first {
        case "\"", "'":
            return parseString(text).map { (.string($0.0), $0.1) }
        case "[":
            var items: [Value] = []
            var rest = text.dropFirst()
            while true {
                rest = rest.drop { $0 == " " || $0 == "\t" }
                if rest.first == "]" { return (.array(items), rest.dropFirst()) }
                guard let (item, after) = parseValue(rest) else { return nil }
                items.append(item)
                rest = after.drop { $0 == " " || $0 == "\t" }
                if rest.first == "," { rest = rest.dropFirst() }
            }
        default:
            let word = text.prefix { !", ]#\t".contains($0) }
            let rest = text.dropFirst(word.count)
            if word == "true" { return (.bool(true), rest) }
            if word == "false" { return (.bool(false), rest) }
            if let integer = Int(word.replacingOccurrences(of: "_", with: "")) {
                return (.integer(integer), rest)
            }
            if let double = Double(word) { return (.float(double), rest) }
            return nil
        }
    }

    /// A `"basic"` or `'literal'` string, with what follows it. Multi-line
    /// strings are not something this document edits, and read as raw.
    private static func parseString(_ text: Substring) -> (String, Substring)? {
        guard let quote = text.first, quote == "\"" || quote == "'",
              !text.hasPrefix("\"\"\""), !text.hasPrefix("'''") else { return nil }
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == quote {
                return (result, text[text.index(after: index)...])
            }
            if quote == "\"", character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
                switch text[index] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "u", "U":
                    let count = text[index] == "u" ? 4 : 8
                    let start = text.index(after: index)
                    guard let end = text.index(start, offsetBy: count, limitedBy: text.endIndex),
                          let code = UInt32(text[start..<end], radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    result.unicodeScalars.append(scalar)
                    index = text.index(before: end)
                default: return nil
                }
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func encode(_ value: Value) -> String {
        switch value {
        case .string(let string): quoted(string)
        case .bool(let bool): bool ? "true" : "false"
        case .integer(let integer): String(integer)
        case .float(let double): String(double)
        case .array(let items): "[" + items.map(encode).joined(separator: ", ") + "]"
        case .raw(let raw): raw
        }
    }

    private static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A key as TOML spells it: bare when it can be, quoted otherwise.
    private static func key(_ name: String) -> String {
        let bare = !name.isEmpty && name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
        return bare ? name : quoted(name)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
