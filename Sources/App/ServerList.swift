import Core
import SwiftUI

/// The saved servers.
struct ServerList: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    /// Driven by the panel header, so the field can sit beside the title
    /// rather than taking a row of its own.
    let search: String
    let open: (Server) -> Void

    @State private var editing: Server?
    @State private var confirmingDeletion: Server?
    /// Multiple rows can be picked with the usual shift and command clicks, so
    /// clearing out a batch of imported hosts is one action rather than a
    /// dozen confirmations.
    @State private var selection: Set<Int64> = []
    @State private var isConfirmingBatchDeletion = false
    /// Servers showing their tunnels. A forward is defined in the server's
    /// editor, but whether it is up belongs out here where it can be watched
    /// and switched off without opening a dialog.
    @State private var expanded: Set<Int64> = []

    private var filtered: [Server] {
        guard !search.isEmpty else { return model.servers }
        let needle = search.lowercased()
        return model.servers.filter {
            $0.name.lowercased().contains(needle)
                || $0.host.lowercased().contains(needle)
                || $0.tags.lowercased().contains(needle)
        }
    }

    /// Servers grouped by their first tag, untagged ones last.
    ///
    /// Tags rather than folders: a server belongs to a project and a machine
    /// class at once, and a tree would force a choice between them. Grouping by
    /// the first tag keeps the list scannable without inventing a hierarchy.
    private var groups: [(name: String?, servers: [Server])] {
        let matching = filtered
        var byTag: [String: [Server]] = [:]
        var untagged: [Server] = []

        for server in matching {
            if let tag = server.tagList.first {
                byTag[tag, default: []].append(server)
            } else {
                untagged.append(server)
            }
        }

        var result = byTag.keys.sorted().map { (name: Optional($0), servers: byTag[$0]!) }
        if !untagged.isEmpty { result.append((name: nil, servers: untagged)) }
        return result
    }

    private var selectedServers: [Server] {
        model.servers.filter { server in server.id.map(selection.contains) ?? false }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.name) { group in
                Section {
                    ForEach(group.servers) { server in
                        row(for: server)
                        if let id = server.id, expanded.contains(id) {
                            ForEach(model.forwards.plainPresets(forServer: id)) { preset in
                                ForwardRow(preset: preset, forwards: model.forwards,
                                           edit: nil)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                } header: {
                    if let name = group.name {
                        Text(name)
                            .font(theme.ui(10, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                    } else if groups.count > 1 {
                        Text("Other")
                            .font(theme.ui(10, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.servers.isEmpty {
                ContentUnavailableView {
                    Label("No servers", systemImage: "server.rack")
                } description: {
                    // No button: Add Server is in the bar below, and an empty
                    // list is not a reason to grow a second one.
                    Text("Add one, or import what is already in ~/.ssh/config.")
                }
            }
        }
        // Delete works on whatever is picked, so a batch is one action.
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            isConfirmingBatchDeletion = true
        }
        .safeAreaInset(edge: .bottom) {
            // One row, one height. Labels with an icon and plain text buttons
            // have different intrinsic heights, so left to itself the row
            // centres each item on its own box and none of them line up.
            HStack(alignment: .center, spacing: 0) {
                footerButton("Add Server", icon: "plus") {
                    editing = Server(name: "", host: "", username: "")
                }

                Spacer(minLength: 8)

                if !selection.isEmpty {
                    footerButton("Clear") { selection = [] }
                    // A gap, because the one beside it is destructive and the
                    // two should not be a slip apart.
                    Spacer().frame(width: 18)
                    footerButton("Delete \(selection.count)", icon: "trash",
                                 tint: .red) {
                        isConfirmingBatchDeletion = true
                    }
                }
            }
            .frame(height: 22)
            .padding(.horizontal, SidePanel.inset)
            .padding(.vertical, 6)
        }
        .alert("Delete \(selection.count) servers?",
               isPresented: $isConfirmingBatchDeletion) {
            Button("Delete", role: .destructive) {
                let doomed = selectedServers
                selection = []
                Task { for server in doomed { await model.delete(server) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their saved port forwards go too. Credentials are kept.")
        }
        .sheet(item: $editing) { server in
            ServerEditor(model: model, server: server)
        }
        .alert(item: $confirmingDeletion) { server in
            // Deleting a server also deletes its port forwards, which is worth
            // saying before it happens rather than after.
            Alert(
                title: Text("Delete \u{201C}\(server.name)\u{201D}?"),
                message: Text("Its saved port forwards go too. Credentials are kept."),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await model.delete(server) }
                },
                secondaryButton: .cancel())
        }
    }

    private func row(for server: Server) -> some View {
        let tunnels = server.id.map { model.forwards.plainPresets(forServer: $0) } ?? []
        return ServerRow(
            server: server,
            tunnels: tunnels.count,
            running: tunnels.filter { model.forwards.status(of: $0) == .running }.count,
            isExpanded: server.id.map(expanded.contains) ?? false,
            toggleExpansion: {
                guard let id = server.id else { return }
                if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            },
            // Worth a mark in the list: it changes where the server's own
            // traffic goes, which is not something to have to remember.
            proxiesBack: server.id.map { model.forwards.proxyBack(for: $0) != nil } ?? false,
            isSelected: server.id.map(selection.contains) ?? false,
            isSelecting: !selection.isEmpty,
            toggleSelection: { toggle(server) },
            connect: { open(server) },
            edit: { editing = server },
            delete: { confirmingDeletion = server })
    }

    private func footerButton(_ title: String, icon: String? = nil,
                              tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 15, height: 15)
                }
                Text(title)
            }
            .font(theme.ui(12))
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? theme.secondaryText)
    }

    private func toggle(_ server: Server) {
        guard let id = server.id else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

}

private struct ServerRow: View {
    @Environment(Theme.self) private var theme
    let server: Server
    /// How many tunnels this server carries, how many are up, and whether
    /// they are showing. The count is coloured when something is actually
    /// running, so it reads as state rather than as a number of saved rows.
    let tunnels: Int
    let running: Int
    let isExpanded: Bool
    let toggleExpansion: () -> Void
    let proxiesBack: Bool
    let isSelected: Bool
    /// True once anything is ticked, so the boxes stay visible while a batch
    /// is being assembled rather than vanishing between hovers.
    let isSelecting: Bool
    let toggleSelection: () -> Void
    let connect: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    private var showsCheckbox: Bool { isSelecting || isHovering }


    var body: some View {
        HStack(spacing: 8) {
            leading

            // Only this part carries the double-click. A tap gesture spanning
            // the whole row swallows the clicks meant for the buttons in it,
            // which made the checkbox impossible to tick.
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name.isEmpty ? server.host : server.name)
                    .font(theme.ui(13))
                    .lineLimit(1)
                Text(address)
                    .font(theme.ui(11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Double-click only. Adding a single-tap alongside it makes every
            // single click wait out the double-click interval first, which
            // reads as the list not responding.
            .onTapGesture(count: 2, perform: connect)

            if tunnels > 0 {
                Button(action: toggleExpansion) {
                    HStack(spacing: 2) {
                        Text(String(tunnels))
                            .font(theme.ui(10, weight: .medium))
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(running > 0 ? theme.accent : theme.secondaryText)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide tunnels" : "Show tunnels")
            }

            if proxiesBack && !isHovering {
                Image(systemName: "arrow.uturn.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .help("Its traffic comes back through this Mac")
            }

            // Only on hover: a column of buttons on every row turns a list of
            // servers into a wall of icons.
            if isHovering && !isSelecting {
                action("play.fill", "Connect", connect)
                action("pencil", "Edit", edit)
                action("trash", "Delete", delete)
            }
        }
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var leading: some View {
        if showsCheckbox {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Image(systemName: server.jumpHostId == nil
                  ? "server.rack" : "arrow.triangle.branch")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 20)
        }
    }

    private func action(_ icon: String, _ title: String,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.secondaryText)
        .help(title)
    }

    /// The port is only worth showing when it is not the one everybody assumes.
    private var address: String {
        let base = "\(server.username)@\(server.host)"
        return server.port == 22 ? base : "\(base):\(server.port)"
    }
}
