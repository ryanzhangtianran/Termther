import Foundation

/// A home directory that exists for one test, so nothing here can read or
/// write the real `~/.claude`, `~/.codex` or `~/.local`.
func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "agents-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
