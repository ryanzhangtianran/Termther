import Core
import SwiftUI

/// The saved servers.
struct ServerList: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    let add: () -> Void
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
    /// The row a dragged server would land on, marked while it is over it.
    @State private var dropTarget: Int64?

    /// Servers grouped by their first tag, untagged ones last.
    ///
    /// Tags rather than folders: a server belongs to a project and a machine
    /// class at once, and a tree would force a choice between them. Grouping by
    /// the first tag keeps the list scannable without inventing a hierarchy.
    private var groups: [(name: String?, servers: [Server])] {
        var byTag: [String: [Server]] = [:]
        var untagged: [Server] = []

        for server in model.servers {
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

    private func move(_ id: Int64, onto target: Server) {
        guard let targetID = target.id else { return }
        let ids = Store.order(model.servers.compactMap(\.id), moving: id, onto: targetID)
        Task { try? await model.store.setServerOrder(ids) }
    }

    private var selectedServers: [Server] {
        model.servers.filter { server in server.id.map(selection.contains) ?? false }
    }

    var body: some View {
        // Plain rows, not a List: a List scrolls itself and has no height of
        // its own, so inside the sidebar it was squeezed to a row or two.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.name) { group in
                if let name = group.name ?? (groups.count > 1 ? "Other" : nil) {
                    // Quieter than the group title above it: a tag is a
                    // subdivision of Connections, not a peer of it.
                    Text(name)
                        .font(theme.ui(12))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                        .padding(.horizontal, SidebarRowStyle.inset)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                ForEach(group.servers) { server in
                    row(for: server)
                        // Dragged by its id; dropped on a row, it takes that
                        // row's place.
                        .draggable(server.id.map(String.init) ?? "")
                        .dropDestination(for: String.self) { items, _ in
                            guard let id = items.first.flatMap({ Int64($0) }) else { return false }
                            move(id, onto: server)
                            return true
                        } isTargeted: { over in
                            if over { dropTarget = server.id } else if dropTarget == server.id { dropTarget = nil }
                        }
                        .overlay {
                            if dropTarget != nil, dropTarget == server.id {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.accent, lineWidth: 1.5)
                            }
                        }
                    if let id = server.id, expanded.contains(id) {
                        ForEach(model.forwards.plainPresets(forServer: id)) { preset in
                            ForwardRow(preset: preset, forwards: model.forwards)
                                .padding(.leading, 16)
                        }
                    }
                }
            }

            if model.servers.isEmpty {
                // Import from ~/.ssh/config lives in the editor this opens.
                AddRow(title: "Add Server", action: add)
            }

            if !selection.isEmpty {
                HStack(spacing: 0) {
                    footerButton("Clear") { selection = [] }
                    Spacer(minLength: 8)
                    // Apart from Clear, because it is destructive and the two
                    // should not be a slip apart.
                    footerButton("Delete \(selection.count)", icon: "trash",
                                 tint: .red) {
                        isConfirmingBatchDeletion = true
                    }
                }
                .padding(.horizontal, SidebarRowStyle.inset)
                .padding(.vertical, 4)
            }
        }
        // Delete works on whatever is picked, so a batch is one action.
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            isConfirmingBatchDeletion = true
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
            Text("Their port forwards are deleted too.")
        }
        .sheet(item: $editing) { server in
            ServerEditor(model: model, server: server)
        }
        .alert(item: $confirmingDeletion) { server in
            // Deleting a server also deletes its port forwards, which is worth
            // saying before it happens rather than after.
            Alert(
                title: Text("Delete \u{201C}\(server.name)\u{201D}?"),
                message: Text("Its port forwards are deleted too."),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await model.delete(server) }
                },
                secondaryButton: .cancel())
        }
    }

    private func row(for server: Server) -> some View {
        // Not the proxy tunnel: that is the switch on the row itself.
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
            proxy: server.id.flatMap { model.forwards.proxyBack(for: $0) }
                .map { model.forwards.status(of: $0) },
            toggleVPN: {
                Task { await model.setRoutesThroughVPN(!server.routesThroughVPN, for: server) }
            },
            toggleProxy: {
                guard let id = server.id else { return }
                Task { await model.forwards.toggleProxyBack(for: id) }
            },
            // What the monitor knows, as a dot on the icon.
            probeError: server.id.flatMap { model.monitor.errors[$0] },
            answered: server.id.map { model.monitor.loads[$0] != nil } ?? false,
            isSelected: server.id.map(selection.contains) ?? false,
            isSelecting: !selection.isEmpty,
            toggleSelection: { toggle(server) },
            connect: { open(server) },
            edit: { editing = server },
            forgetHostKey: { Task { try? await model.store.forgetHostKey(host: server.host, port: server.port) } },
            delete: { confirmingDeletion = server })
    }

    private func footerButton(_ title: String, icon: String? = nil,
                              tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
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
    /// The proxy tunnel's state, or nil when the server has none.
    let proxy: Forwards.Status?
    let toggleVPN: () -> Void
    let toggleProxy: () -> Void
    /// Why the last probe failed, and whether one was ever answered.
    let probeError: String?
    let answered: Bool
    let isSelected: Bool
    /// True once anything is ticked, so the boxes stay visible while a batch
    /// is being assembled rather than vanishing between hovers.
    let isSelecting: Bool
    let toggleSelection: () -> Void
    let connect: () -> Void
    let edit: () -> Void
    let forgetHostKey: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    private var showsCheckbox: Bool { isSelecting || isHovering }


    var body: some View {
        // The address opens under the row on hover, at once rather than after
        // a tooltip's wait. A line of its own, under the buttons too: beside
        // them, the ones that slide in on hover leave it no room.
        VStack(alignment: .leading, spacing: 1) {
            mainLine
            if isHovering {
                Text(address)
                    .font(theme.ui(11, weight: SidebarRowStyle.titleWeight))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    // Smaller first, then the middle elided: the user and the
                    // port are the ends worth keeping.
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
                    .padding(.leading, SidebarRowStyle.iconColumn + SidebarRowStyle.iconGap)
                    .transition(.opacity)
            }
        }
        .sidebarRow(hovering: isHovering, selected: isSelected)
        .onHover { hovering in
            // Eased, so buttons that appear on hover slide in rather than pop.
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
        // Copying by menu, not by selecting the text: the row already answers
        // clicks and double-clicks, and a selectable label would fight them.
        .contextMenu { menu }
    }

    private var mainLine: some View {
        HStack(spacing: SidebarRowStyle.iconGap) {
            leading

            // Only this part carries the double-click. A tap gesture spanning
            // the whole row swallows the clicks meant for the buttons in it,
            // which made the checkbox impossible to tick.
            Text(server.displayName)
                .font(theme.ui(12, weight: SidebarRowStyle.titleWeight))
                .tracking(SidebarRowStyle.titleTracking)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Double-click only. Adding a single-tap alongside it makes every
            // single click wait out the double-click interval first, which
            // reads as the list not responding.
            .onTapGesture(count: 2, perform: connect)

            if tunnels > 0 {
                // A chevron alone; the count is on hover, not on the row.
                Button(action: toggleExpansion) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(running > 0 ? theme.accent : theme.secondaryText)
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tunnels == 1 ? "1 tunnel" : "\(tunnels) tunnels")
            }

            // One family of icons, one size, one hit target: the row's marks
            // and switches read as a set rather than an assortment.
            HStack(spacing: 2) {
                // A switch: always shown while on, and on hover to turn on --
                // an idle switch on every row is noise.
                if proxy.map({ $0 != .stopped }) ?? false || isHovering {
                    Button(action: toggleProxy) { icon("globe", proxy?.color(stopped: theme.secondaryText.opacity(0.4)) ?? theme.secondaryText.opacity(0.4)) }
                        .buttonStyle(.plain)
                        .help(proxyHelp)
                        .transition(.revealFromTrailing)
                }

                // Only on hover: a column of buttons on every row turns a list
                // of servers into a wall of icons. Delete is in the menu.
                if isHovering && !isSelecting {
                    Group {
                        action("play.circle", "Connect", connect)
                        action("info.circle", "Details", edit)
                    }
                    .transition(.revealFromTrailing)
                }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
            Button("Connect", action: connect)
            Button("Details\u{2026}", action: edit)
            Divider()
            // In the menu rather than on the row: a switch that sits beside
            // the proxy's is one mis-click from sending a public server into
            // a campus gateway that will not route it.
            Toggle("Through the VPN", isOn: Binding(
                get: { server.routesThroughVPN }, set: { _ in toggleVPN() }))
            Divider()
            Button("Copy Address") { copyToPasteboard(address) }
            Button("Copy Host") { copyToPasteboard(server.host) }
            Divider()
            Button("Forget Host Key", action: forgetHostKey)
            Button("Delete\u{2026}", role: .destructive, action: delete)
    }

    private var proxyHelp: String {
        switch proxy {
        case .running?:               "Proxied \u{2014} click to stop"
        case .starting?, .retrying?:  "Connecting\u{2026}"
        case .failed(let why)?:       "\(why) \u{2014} click to retry"
        case .stopped?, nil:          "Proxy through this Mac"
        }
    }

    @ViewBuilder
    private var leading: some View {
        if showsCheckbox {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .sidebarIcon()
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .frame(height: SidebarRowStyle.iconColumn)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Image(systemName: server.jumpHostID == nil
                  ? "laptopcomputer" : "arrow.triangle.branch")
                .sidebarIcon()
                .foregroundStyle(theme.text)
                // Reached through the VPN: said on the server's own icon, the
                // way Finder badges a shared folder, rather than as a control.
                .overlay(alignment: .bottomTrailing) {
                    if server.routesThroughVPN {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, theme.accent)
                            .padding(1)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                            .offset(x: 3, y: 3)
                            .help("Through the VPN")
                    }
                }
                // Whether it answered the last probe, on the other corner:
                // green for an answer, red for a failure.
                .overlay(alignment: .topTrailing) {
                    if probeError != nil || answered {
                        Circle()
                            .fill(probeError == nil ? .green : .red)
                            .frame(width: 5, height: 5)
                            .padding(1)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                            .offset(x: 2, y: -2)
                    }
                }
        }
    }

    private func action(_ name: String, _ title: String,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { icon(name, theme.secondaryText) }
            .buttonStyle(.plain)
            .help(title)
    }

    /// Every trailing icon on the row: outline, one size, a 22pt target.
    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: SidebarRowStyle.trailingIconSize,
                          weight: SidebarRowStyle.iconWeight))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }

    /// With the port always, so it reads the same on every row.
    private var address: String { "\(server.username)@\(server.host):\(server.port)" }
}
