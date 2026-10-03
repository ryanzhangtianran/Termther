import Core
import SwiftUI

/// The Sessions section of an agent's page: the transcripts it has left
/// behind, one row each, with a preview of the one picked.
///
/// Plain rows after the sidebar's manner, not a List: a circle at the left
/// ticks a row into a batch to delete, a click on the body picks it for the
/// preview, a double-click resumes it.
struct AgentSessionsView: View {
    @Environment(Theme.self) private var theme
    let tool: AgentTool
    let agents: Agents
    let workspace: Workspace

    @State private var search = ""
    /// Ticked, for deletion.
    @State private var selection: Set<String> = []
    /// Picked, for the preview.
    @State private var highlighted: String?
    /// Waiting on the confirmation.
    @State private var doomed: [AgentSession] = []
    @State private var transcript: [(role: String, text: String)] = []
    @State private var limit = Self.page

    /// How many rows are shown before "Show more".
    static let page = 200

    private var info: Agents.Info { agents[tool] }

    /// The sessions worth a row: the stale ones are counted, not listed.
    private var stale: [AgentSession] { info.sessions.filter(\.isStale) }

    private var filtered: [AgentSession] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let listed = info.sessions.filter { !$0.isStale }
        guard !query.isEmpty else { return listed }
        return listed.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    private var highlightedSession: AgentSession? {
        highlighted.flatMap { id in info.sessions.first { $0.id == id } }
    }

    private var selected: [AgentSession] { info.sessions.filter { selection.contains($0.id) } }

    var body: some View {
        Section {
            TextField("Search", text: $search, prompt: Text("Search"))
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 4)
            if info.sessions.isEmpty {
                Text("No sessions")
                    .foregroundStyle(theme.secondaryText)
            } else if filtered.isEmpty {
                Text("No matches")
                    .foregroundStyle(theme.secondaryText)
            } else {
                VStack(spacing: 2) {
                    ForEach(filtered.prefix(limit)) { session in
                        SessionRow(session: session, detail: detail(of: session),
                                   isSelected: selection.contains(session.id),
                                   isHighlighted: session.id == highlighted,
                                   toggleSelection: { selection.formSymmetricDifference([session.id]) },
                                   highlight: { highlighted = session.id },
                                   resume: { agents.resume(session, in: workspace) },
                                   delete: {
                                       // The row's own, unless it is one of several ticked.
                                       doomed = selection.contains(session.id) ? selected : [session]
                                   })
                    }
                    if filtered.count > limit {
                        Button("Show more (\(filtered.count - limit) left)") { limit += Self.page }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.accent)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            if highlightedSession != nil {
                preview
            }
        } header: {
            HStack(spacing: 12) {
                Text("Sessions")
                Spacer()
                if !selection.isEmpty {
                    Button("Delete \(selection.count)\u{2026}") { doomed = selected }
                        .foregroundStyle(.red)
                }
                Button(selection.isEmpty ? "Select All" : "Deselect") {
                    selection = selection.isEmpty ? Set(filtered.map(\.id)) : []
                }
                .disabled(filtered.isEmpty)
                if !stale.isEmpty {
                    Button("Delete \(stale.count) Stale\u{2026}") { doomed = stale }
                }
                Button("Reload") { Task { await agents.refreshSessions(tool) } }
            }
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
            Text(doomed.prefix(8).map(\.title).joined(separator: "\n")
                 + (doomed.count > 8 ? "\n\u{2026}and \(doomed.count - 8) more" : ""))
        }
    }

    /// `cwd · when · size · tokens`, on one line.
    private func detail(of session: AgentSession) -> String {
        [(session.cwd as NSString).abbreviatingWithTildeInPath,
         session.modified.formatted(.relative(presentation: .named)),
         ByteCountFormatter.string(fromByteCount: Int64(session.size), countStyle: .file),
         session.tokens.total.formatted(.number.notation(.compactName)) + " tokens"]
            .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// The transcript of the picked session: the user's turns marked in the
    /// accent, the assistant's dimmed.
    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(transcript.prefix(40).enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 6) {
                        if entry.role == "user" {
                            Text("\u{258C}").foregroundStyle(theme.accent)
                        }
                        Text(entry.text)
                            .foregroundStyle(entry.role == "user" ? theme.text : theme.secondaryText)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .frame(height: 260)
    }
}

/// One session: the circle, the title over its details, and the play button.
private struct SessionRow: View {
    @Environment(Theme.self) private var theme
    let session: AgentSession
    let detail: String
    let isSelected: Bool
    let isHighlighted: Bool
    let toggleSelection: () -> Void
    let highlight: () -> Void
    let resume: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SidebarRowStyle.iconGap) {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .sidebarIcon()
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .frame(height: SidebarRowStyle.iconColumn)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(detail)
                    .font(theme.ui(12))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // A single click picks; ⌘-click ticks the circle as well; a
            // double-click resumes. The double-click is declared first so a
            // single click does not wait out the interval.
            .onTapGesture(count: 2, perform: resume)
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) { toggleSelection() } else { highlight() }
            }

            Button(action: resume) {
                Image(systemName: "play.fill")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help("Resume")
        }
        .sidebarRow(hovering: isHovering, selected: isHighlighted)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Resume", action: resume)
            Button(isSelected ? "Deselect" : "Select", action: toggleSelection)
            Divider()
            Button("Delete\u{2026}", role: .destructive, action: delete)
        }
    }
}
