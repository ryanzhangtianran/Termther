import Core
import SwiftUI

/// The Sessions page: every transcript either tool has left behind, in one
/// list, and the one picked beside it -- its particulars, the command that
/// picks it up again, and what was said.
///
/// Plain rows after the sidebar's manner, not a List: a circle at the left
/// ticks a row into a batch to delete, a click on the body picks it, a
/// double-click resumes it.
struct SessionsSettings: View {
    @Environment(Theme.self) private var theme
    let agents: Agents
    let workspace: Workspace

    @State private var search = ""
    /// Ticked, for deletion.
    @State private var selection: Set<String> = []
    /// Picked, for the detail.
    @State private var highlighted: String?
    /// Waiting on the confirmation.
    @State private var doomed: [AgentSession] = []
    @State private var transcript: [(role: String, text: String)] = []
    @State private var limit = Self.page

    /// How many rows are shown before "Show more".
    static let page = 200

    /// Both tools' sessions, newest first.
    private var sessions: [AgentSession] {
        AgentTool.allCases.flatMap { agents[$0].sessions }.sorted { $0.modified > $1.modified }
    }

    /// Given `sessions`, which `list` works out once per render: sorting
    /// both tools' sessions for every use, every row included, was most of
    /// what a keystroke in the search field cost.
    private func filtered(_ sessions: [AgentSession]) -> [AgentSession] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let listed = sessions.filter { !$0.isStale }
        guard !query.isEmpty else { return listed }
        return listed.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    private var highlightedSession: AgentSession? {
        highlighted.flatMap { id in sessions.first { $0.id == id } }
    }

    private var selected: [AgentSession] { sessions.filter { selection.contains($0.id) } }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                card { list }
                    .frame(width: 400)
                card { detail }
            }
            // The pane's height, less the page's bottom margin: the list is
            // what this page is, so it takes the room there is.
            .containerRelativeFrame(.vertical) { length, _ in max(480, length - 60) }
        }
        .bareSection()
        .task {
            async let claude: Void = agents.refreshSessions(.claude)
            await agents.refreshSessions(.codex)
            await claude
        }
        .task(id: highlighted) {
            guard let session = highlightedSession else { transcript = []; return }
            transcript = await Task.detached { AgentSession.transcript(of: session) }.value
        }
        .onChange(of: search) { limit = Self.page }
        .alert(doomed.count == 1 ? "Delete this session?" : "Delete \(doomed.count) sessions?",
               isPresented: Binding(get: { !doomed.isEmpty }, set: { if !$0 { doomed = [] } })) {
            Button("Delete", role: .destructive) {
                let sessions = doomed
                selection.subtract(sessions.map(\.id))
                if let highlighted, sessions.contains(where: { $0.id == highlighted }) { self.highlighted = nil }
                Task { await agents.deleteSessions(sessions) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Named where they have names; the empty ones are only counted,
            // since a list of dashes says nothing.
            let named = doomed.filter { $0.title != "\u{2014}" }
            let empty = doomed.count - named.count
            Text((named.prefix(8).map(\.title)
                  + (named.count > 8 ? ["\u{2026}and \(named.count - 8) more"] : [])
                  + (empty == 0 ? [] : [empty == 1 ? "1 empty session" : "\(empty) empty sessions, with nothing in them"]))
                .joined(separator: "\n"))
        }
    }

    /// The bordered card both halves of the page sit in.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .plate()
    }

    // MARK: - the list

    private var list: some View {
        let sessions = self.sessions
        // The sessions worth a row: the stale ones are counted, not listed.
        let stale = sessions.filter(\.isStale)
        let filtered = filtered(sessions)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Sessions")
                    .font(theme.ui(14, weight: .medium))
                Text("\(filtered.count)")
                    .font(theme.ui(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.text.opacity(0.08), in: Capsule())
                Spacer()
                // Deletes what is ticked, and nothing until something is.
                Button("Delete") { doomed = selected }
                    .buttonStyle(.plateDestructive)
                    .disabled(selection.isEmpty)
                TileButton(symbol: "checkmark", color: selection.isEmpty ? nil : theme.accent,
                           help: selection.isEmpty ? "Select All" : "Deselect") {
                    selection = selection.isEmpty ? Set(filtered.map(\.id)) : []
                }
                .disabled(filtered.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider().padding(.horizontal, 16)
            TextField("Search", text: $search, prompt: Text("Search"))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            if sessions.isEmpty {
                Text("No sessions")
                    .foregroundStyle(theme.secondaryText)
                    .padding(16)
            } else if filtered.isEmpty {
                Text("No matches")
                    .foregroundStyle(theme.secondaryText)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filtered.prefix(limit)) { session in
                            SessionRow(session: session,
                                       isSelected: selection.contains(session.id),
                                       isHighlighted: session.id == highlighted,
                                       toggleSelection: { selection.formSymmetricDifference([session.id]) },
                                       highlight: { highlighted = session.id },
                                       resume: { agents.resume(session, in: workspace) },
                                       delete: {
                                           // The row's own, unless it is one of several ticked.
                                           doomed = selection.contains(session.id) ? selected : [session]
                                       },
                                       empties: stale.count,
                                       deleteEmpties: { doomed = stale })
                        }
                        if filtered.count > limit {
                            Button("Show more (\(filtered.count - limit) left)") { limit += Self.page }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.accent)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - the picked one

    @ViewBuilder
    private var detail: some View {
        if let session = highlightedSession {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Tile(image: session.tool.logo, size: 28)
                        Text(session.title)
                            .font(theme.ui(15, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Button("Resume") { agents.resume(session, in: workspace) }
                            .buttonStyle(.plateProminent)
                        Button("Delete") { doomed = [session] }
                            .buttonStyle(.plateDestructive)
                    }
                    // Date, place, file, size and tokens are on hover.
                    .help([session.modified.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(.chrome)),
                           (session.cwd as NSString).abbreviatingWithTildeInPath,
                           session.path.lastPathComponent,
                           ByteCountFormatter.string(fromByteCount: Int64(session.size), countStyle: .file),
                           session.tokens.total.formatted(.number.notation(.compactName).locale(.chrome)) + " tokens"]
                        .filter { !$0.isEmpty }.joined(separator: "\n"))
                    Text(session.resumeCommand)
                        .font(theme.ui(12, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.text.opacity(0.06), in: .rect(cornerRadius: 8))
                }
                .padding(16)
                Divider().padding(.horizontal, 16)
                transcriptView
            }
        } else {
            Text("No session picked")
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What was said, the latest 200 turns: the user's marked in the
    /// accent, the assistant's dimmed.
    private var transcriptView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(transcript.suffix(200).enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.role.uppercased())
                            .font(theme.ui(10.5, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(entry.role == "user" ? theme.accent : theme.secondaryText)
                        Text(entry.text)
                            .font(theme.ui(12.5))
                            .foregroundStyle(entry.role == "user" ? theme.text : theme.secondaryText)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        // Opened on the latest turn, as a terminal is.
        .defaultScrollAnchor(.bottom)
    }
}

/// One session: the circle, the tool's logo, the title over its details,
/// and the play button.
private struct SessionRow: View {
    @Environment(Theme.self) private var theme
    let session: AgentSession
    let isSelected: Bool
    let isHighlighted: Bool
    let toggleSelection: () -> Void
    let highlight: () -> Void
    let resume: () -> Void
    let delete: () -> Void
    /// The sessions not listed -- nothing said in them, or taken over by
    /// another -- which the menu offers to clear out.
    let empties: Int
    let deleteEmpties: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SidebarRowStyle.iconGap) {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .frame(width: SidebarRowStyle.iconColumn)
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .frame(height: SidebarRowStyle.iconColumn)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Tile(image: session.tool.logo)

            HStack(spacing: 8) {
                Text(session.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // When, at the row's end; where it ran is on hover.
                Text(session.modified.formatted(.relative(presentation: .named).locale(.chrome)))
                    .font(theme.ui(12))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .help((session.cwd as NSString).abbreviatingWithTildeInPath)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // A single click picks; ⌘-click ticks the circle as well; a
            // double-click resumes. The double-click is declared first so a
            // single click does not wait out the interval.
            .onTapGesture(count: 2, perform: resume)
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) { toggleSelection() } else { highlight() }
            }

            TileButton(symbol: "play.fill", help: "Resume", action: resume)
        }
        .sidebarRow(hovering: isHovering, selected: isHighlighted)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Resume", action: resume)
            Button(isSelected ? "Deselect" : "Select", action: toggleSelection)
            Divider()
            Button("Delete", role: .destructive, action: delete)
            if empties > 0 {
                Button(empties == 1 ? "Delete 1 Hidden Session" : "Delete \(empties) Hidden Sessions",
                       role: .destructive, action: deleteEmpties)
            }
        }
    }
}

