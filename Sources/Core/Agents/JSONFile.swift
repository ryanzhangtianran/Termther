import Foundation

/// A JSON file holding one object, read and written whole.
///
/// Claude Code's `settings.json` and `~/.claude.json` and Codex's `auth.json`
/// are all of this shape, and all hold far more than this app knows about.
/// Reading gives every key; writing puts every key back, so an edit to one
/// leaves the rest. Only the formatting is the app's own.
enum JSONFile {
    enum Failure: Error, CustomStringConvertible {
        case notObject(URL)

        var description: String {
            switch self {
            case .notObject(let url): "\(url.path) does not hold a JSON object, so Termther leaves it alone."
            }
        }
    }

    /// The object in the file, or an empty one when there is no file yet.
    static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        else { throw Failure.notObject(url) }
        return object
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data(object).write(to: url, options: .atomic)
    }

    /// The one way an object is written, so two writes of equal objects are
    /// equal bytes.
    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object,
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.notObject(URL(fileURLWithPath: "-")) }
        return object
    }
}
