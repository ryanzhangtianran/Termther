import Foundation

/// A coding agent that lives on this Mac and keeps its state in dotfiles.
///
/// Termther manages two of them the same way: saved copies of each one's
/// settings files, its MCP servers, its prompt file, its skills, and the
/// sessions it has left behind. What differs is where each keeps those
/// things, which `AgentPaths` answers -- so nothing else needs to know that
/// one is JSON and one is TOML.
public enum AgentTool: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The executable, as typed in a shell.
    public var command: String { rawValue }

    public func paths(home: URL = .homeDirectory, data: URL? = nil) -> AgentPaths {
        AgentPaths(self, home: home, data: data)
    }
}

/// Where one tool keeps its files, under one home directory.
///
/// Every function that reads or writes a tool's state takes one of these
/// rather than reaching for `~` itself, so a test can point the whole feature
/// at a temporary directory and never touch the real files.
public struct AgentPaths: Sendable, Equatable {
    public let tool: AgentTool
    public let home: URL
    /// Termther's own directory, where the profiles are kept: `~/.termther`
    /// unless Settings moved it.
    public let data: URL

    public init(_ tool: AgentTool, home: URL = .homeDirectory, data: URL? = nil) {
        self.tool = tool
        self.home = home
        self.data = data ?? home.appending(path: ".termther", directoryHint: .isDirectory)
    }

    /// `~/.claude` or `~/.codex`.
    public var directory: URL {
        home.appending(path: tool == .claude ? ".claude" : ".codex", directoryHint: .isDirectory)
    }

    /// The tool's settings: `settings.json` or `config.toml`.
    public var settings: URL {
        directory.appending(path: tool == .claude ? "settings.json" : "config.toml")
    }

    /// Where saved copies of the settings files live, one directory per
    /// profile: `~/.termther/agents/claude` or `.../codex`.
    public var profiles: URL {
        data.appending(path: "agents/\(tool.rawValue)", directoryHint: .isDirectory)
    }

    /// The files a profile holds, named as they are in `directory`: Claude
    /// Code's `settings.json`; Codex's `config.toml` and `auth.json`, since
    /// the key that goes with a `config.toml` lives in the other.
    public var profileFiles: [String] {
        tool == .claude ? ["settings.json"] : ["config.toml", "auth.json"]
    }

    /// Where the MCP servers are declared. Claude Code keeps them beside the
    /// directory, in `~/.claude.json`; Codex keeps them in `config.toml`.
    public var mcpConfig: URL {
        tool == .claude ? home.appending(path: ".claude.json") : settings
    }

    /// `CLAUDE.md` or `AGENTS.md`: what the agent reads before every session.
    public var prompt: URL {
        directory.appending(path: tool == .claude ? "CLAUDE.md" : "AGENTS.md")
    }

    public var skills: URL { directory.appending(path: "skills", directoryHint: .isDirectory) }

    /// The directory holding session transcripts: `projects` for Claude Code,
    /// grouped by working directory; `sessions` for Codex, grouped by date.
    public var sessions: URL {
        directory.appending(path: tool == .claude ? "projects" : "sessions", directoryHint: .isDirectory)
    }

    /// Codex only: the titles it gives sessions, one JSON line each.
    public var sessionIndex: URL { directory.appending(path: "session_index.jsonl") }

    /// The tool's executable: `~/.local/bin/claude` or `~/.local/bin/codex`.
    /// For Claude Code that is the launcher, which `ClaudeLauncher` points
    /// at one of the versions.
    public var command: URL { home.appending(path: ".local/bin/\(tool.command)") }

    /// Claude Code only: the versions installed, one binary each.
    public var versions: URL {
        home.appending(path: ".local/share/claude/versions", directoryHint: .isDirectory)
    }
}
