import Core
import SwiftUI

/// The MCP page: every server either tool knows, one row each, with a
/// switch per tool -- its logo, lit where the server is on for it.
///
/// A click on a lit logo turns the server off for that tool; on a dim one,
/// turns it on, copying the server over first if that tool lacks it. The
/// pencil edits the server for both; the bin removes it from both.
struct MCPSettings: View {
    @Environment(Theme.self) private var theme
    let agents: Agents

    @State private var editing: Editing?
    @State private var confirmingDeletion: MCPServer?

    private struct Editing: Identifiable {
        let server: MCPServer
        let id = UUID()
    }

    /// Each server once, by name, as the first tool that has it describes
    /// it; Claude Code's list first, then Codex's additions.
    private var servers: [MCPServer] {
        var seen: Set<String> = []
        return AgentTool.allCases.flatMap { agents[$0].mcp }.filter { seen.insert($0.name).inserted }
    }

    var body: some View {
        Section {
            ForEach(servers) { server in
                HStack(spacing: 14) {
                    Text(server.name)
                    .help(server.url.isEmpty
                          ? ([server.command] + server.args).joined(separator: " ") : server.url)
                    Spacer()
                    ForEach(AgentTool.allCases, id: \.self) { tool in
                        toolSwitch(server, tool)
                    }
                    TileButton(symbol: "pencil", help: "Edit") { editing = Editing(server: server) }
                    TileButton(symbol: "trash", color: theme.failing, help: "Delete") { confirmingDeletion = server }
                }
            }
            if servers.isEmpty {
                Text("No MCP servers")
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            HStack {
                Text("Servers")
                Spacer()
                TileButton(symbol: "plus", size: 20, help: "Add Server") { editing = Editing(server: MCPServer(name: "")) }
            }
        }
        .task {
            await agents.refreshAll()
        }
        .sheet(item: $editing) { editing in
            MCPServerEditor(server: editing.server) { server in
                Task {
                    // A new server goes to both; an edited one to each tool
                    // that had it, keeping that tool's switch.
                    for tool in AgentTool.allCases {
                        let list = agents[tool].mcp
                        if let index = list.firstIndex(where: { $0.name == editing.server.name }) {
                            var servers = list
                            var replaced = server
                            replaced.enabled = list[index].enabled
                            servers[index] = replaced
                            await agents.setMCP(servers, for: tool)
                        } else if editing.server.name.isEmpty {
                            await agents.setMCP(list + [server], for: tool)
                        }
                    }
                }
            }
        }
        .alert(item: $confirmingDeletion) { server in
            Alert(title: Text("Delete \u{201C}\(server.name)\u{201D}?"),
                  message: Text("It is removed from both tools."),
                  primaryButton: .destructive(Text("Delete")) {
                      Task {
                          for tool in AgentTool.allCases {
                              await agents.setMCP(agents[tool].mcp.filter { $0.name != server.name }, for: tool)
                          }
                      }
                  },
                  secondaryButton: .cancel())
        }
    }

    /// The tool's logo: lit when the server is on for it, dim otherwise.
    private func toolSwitch(_ server: MCPServer, _ tool: AgentTool) -> some View {
        let own = agents[tool].mcp.first { $0.name == server.name }
        let isOn = own?.enabled == true
        return Button {
            Task {
                if var own {
                    own.enabled.toggle()
                    await agents.setMCP(agents[tool].mcp.map { $0.name == own.name ? own : $0 }, for: tool)
                } else {
                    var copy = server
                    copy.enabled = true
                    await agents.copyMCP(copy, to: tool)
                }
            }
        } label: {
            // The tool's own tile, lit when the server is on for it.
            Tile(image: tool.logo, size: 26)
                .opacity(isOn ? 1 : 0.3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "On for \(tool.title)" : "Off for \(tool.title)")
    }
}
