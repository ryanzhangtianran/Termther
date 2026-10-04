import Foundation

/// A tool server an agent can call, as both tools describe one: a command to
/// run and talk to over stdio, or a URL to reach over HTTP.
///
/// `enabled` is Codex's notion. Claude Code has no such flag, so a disabled
/// server is simply left out when its list is written -- to keep it, keep it
/// enabled.
public struct MCPServer: Equatable, Identifiable, Sendable {
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]
    /// Set for a remote server, in place of a command.
    public var url: String
    public var enabled: Bool

    public init(name: String, command: String = "", args: [String] = [],
                env: [String: String] = [:], url: String = "", enabled: Bool = true) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.enabled = enabled
    }

    public var id: String { name }
}
