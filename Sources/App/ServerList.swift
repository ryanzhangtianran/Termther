import AppKit
import Core
import SwiftUI

/// The saved servers, each with the terminals open on it under it, and the
/// local shells at the end, under Local.
struct ServerList: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    let workspace: Workspace
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

    /// The terminal tabs whose session -- the pane with the keyboard -- is
    /// one `belongs` picks.
    private func tabs(_ belongs: (TerminalSession) -> Bool) -> [Workspace.Tab] {
        workspace.tabs.filter { tab in tab.session.map(belongs) ?? false }
    }

    private var selectedServers: [Server] {
        model.servers.filter { server in server.id.map(selection.contains) ?? false }
    }

    var body: some View {
        // Plain rows, not a List: a List scrolls itself and has no height of
        // its own, so inside the sidebar it was squeezed to a row or two.
        let groups = self.groups
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.name) { group in
                if let name = group.name ?? (groups.count > 1 ? "Other" : nil) {
                    // Quieter than the group title above it: a tag is a
                    // subdivision of Connections, not a peer of it.
                    Text(name)
                        .font(theme.ui(10.5, weight: .medium))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                        .padding(.leading, SidebarRowStyle.inset + 2)
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
                                RoundedRectangle(cornerRadius: SidebarRowStyle.cornerRadius, style: .continuous)
                                    .stroke(theme.accent, lineWidth: 1.5)
                            }
                        }
                    if let id = server.id, expanded.contains(id) {
                        ForEach(model.forwards.plainPresets(forServer: id)) { preset in
                            ForwardRow(preset: preset, forwards: model.forwards)
                                .padding(.leading, 16)
                        }
                    }
                    ForEach(tabs { $0.serverID == server.id && server.id != nil }) { tab in
                        SessionRow(tab: tab, workspace: workspace, model: model)
                    }
                }
            }

            // This Mac's own shells, under a heading of their own -- always
            // there, since its + is where a new one is opened.
            HStack {
                // A peer of Servers, so it is titled the way that is.
                Text("Local")
                    .font(theme.ui(12.5, weight: .semibold))
                    .foregroundStyle(theme.text.opacity(0.5))
                Spacer()
                TileButton(symbol: "plus", size: 20, help: "New Terminal") { _ = workspace.newLocalTab() }
            }
            .padding(.leading, SidebarRowStyle.inset)
            .padding(.trailing, 4)
            .padding(.top, 16)
            .padding(.bottom, 4)
            ForEach(tabs { $0.isLocal }) { tab in
                SessionRow(tab: tab, workspace: workspace, model: model)
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
            load: server.id.flatMap { model.monitor.loads[$0] },
            waitsForVPN: model.needsTunnel(server),
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
    /// Why the last probe failed, and what the last answer said.
    let probeError: String?
    let load: ServerLoad?
    /// Behind the VPN while it is down: not a failure, so a chip of its own.
    let waitsForVPN: Bool
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

    private var isConnected: Bool { load != nil && probeError == nil }

    var body: some View {
        mainLine
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
            // The group's colour; a box in its place while a batch is being
            // picked.
            if isSelecting {
                Button(action: toggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                        .frame(width: SidebarRowStyle.iconColumn)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                Tile(symbol: server.jumpHostID == nil ? "server.rack" : "arrow.triangle.branch",
                     size: SidebarRowStyle.iconColumn)
            }

            // Only this part carries the double-click. A tap gesture spanning
            // the whole row swallows the clicks meant for the buttons in it,
            // which made the checkbox impossible to tick.
            // Through the VPN or not is on hover with the address, and its
            // dot goes yellow while the VPN is down: a lock on the name
            // read as something locked.
            Text(server.displayName)
                .font(theme.ui(SidebarRowStyle.titleSize, weight: SidebarRowStyle.titleWeight))
                .foregroundStyle(theme.text.opacity(isSelected ? 1 : 0.86))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help([address, server.routesThroughVPN ? "Through the VPN" : nil,
                       load.map(Self.summary) ?? probeError].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: "\n"))
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
                // The proxy shows while it is on, so its state is seen, and
                // on hover, dim, so it can be turned back on where it went.
                if proxy.map({ $0 != .stopped }) ?? false || (isHovering && !isSelecting) {
                    TileButton(symbol: "globe", color: proxy?.color(stopped: theme.secondaryText),
                               size: 20, help: proxyHelp, action: toggleProxy)
                }

                // On hover, the one thing a row is most often for; the rest
                // is in its menu, on a right click.
                if isHovering && !isSelecting {
                    TileButton(symbol: "apple.terminal", size: 20, help: "Open a Terminal", action: connect)
                        .transition(.revealFromTrailing)
                } else {
                    // Its state, as a dot at the row's end: green answering,
                    // red failing, yellow waiting for the VPN, dim otherwise.
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .frame(width: 20, height: 20)
                }
            }
        }
    }

    private var statusColor: Color {
        if probeError != nil { return theme.failing }
        if isConnected { return theme.online }
        if waitsForVPN { return theme.waiting }
        return theme.text.opacity(0.18)
    }

    @ViewBuilder
    private var menu: some View {
            Button("Connect", action: connect)
            Button("Details", action: edit)
            Button(isSelected ? "Deselect" : "Select", action: toggleSelection)
            Divider()
            Toggle("Proxy through This Mac", isOn: Binding(
                get: { proxy.map { $0 != .stopped } ?? false }, set: { _ in toggleProxy() }))
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
            Button("Delete", role: .destructive, action: delete)
    }

    private var proxyHelp: String {
        switch proxy {
        case .running?:               "Proxied \u{2014} click to stop"
        case .starting?, .retrying?:  "Connecting\u{2026}"
        case .failed(let why)?:       "\(why) \u{2014} click to stop"
        case .stopped?, nil:          "Proxy through this Mac"
        }
    }

    /// The load as a line for the tooltip.
    static func summary(_ load: ServerLoad) -> String {
        var parts: [String] = []
        if let cpu = load.cpuPercent { parts.append("CPU \(Int(cpu.rounded()))%") }
        if let used = load.memoryUsed, let total = load.memoryTotal, total > 0 {
            parts.append("MEM \(Int((Double(used) / Double(total) * 100).rounded()))%")
        }
        if let load1 = load.load1 { parts.append(String(format: "load %.2f", load1)) }
        if let disk = load.diskUsedPercent { parts.append("disk \(Int(disk))%") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// With the port always, so it reads the same on every row.
    private var address: String { "\(server.username)@\(server.host):\(server.port)" }
}

/// A terminal open on a server, under the server's row: where it is,
/// picked with a click. It carries what the tab does: a dot when it wants
/// looking at, its bandwidth, and on hover the proxy switch, an agent to
/// run in it, and close -- the proxy staying in view while it is on.
private struct SessionRow: View {
    @Environment(Theme.self) private var theme
    let tab: Workspace.Tab
    let workspace: Workspace
    let model: AppModel

    @State private var isHovering = false

    private var session: TerminalSession? { tab.session }
    private var isSelected: Bool { tab.id == workspace.selection }

    /// "ryan@web-1: ~/train" says the server twice under the server's own
    /// row; the part after the colon is what tells two of them apart.
    private var place: String {
        let title = tab.title
        guard let colon = title.range(of: ": ") else { return title }
        return String(title[colon.upperBound...])
    }

    var body: some View {
        // Under a server or under Local, a session looks the same: indented,
        // with a small glyph, a step below the rows it sits under.
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText.opacity(0.7))
                .frame(width: SidebarRowStyle.iconColumn)
            if tab.tree?.leaves.contains(where: \.needsAttention) == true {
                Circle().fill(theme.accent).frame(width: 6, height: 6)
            }
            Text(place)
                .font(theme.ui(SidebarRowStyle.childTitleSize, weight: SidebarRowStyle.titleWeight))
                .foregroundStyle(session?.isDisconnected == true ? theme.failing : theme.text.opacity(isSelected ? 1 : 0.86))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(session?.isDisconnected == true ? "\(tab.title) \u{2014} disconnected" : tab.title)
            Spacer(minLength: 4)
            if let bandwidth, !isHovering {
                Text(bandwidth)
                    .font(theme.ui(11).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize()
            }
            HStack(spacing: 4) {
                if let session, !session.isDisconnected, session.usesProxy || isHovering {
                    TileButton(symbol: "globe", color: proxyColor(session), size: 20,
                               help: session.usesProxy ? "Proxied \u{2014} click to stop" : "Proxy This Terminal") {
                        toggleProxy(session)
                    }
                }
                if isHovering, let session {
                    ForEach(AgentTool.allCases, id: \.self) { tool in
                        TileButton(image: tool.logo, size: 20, help: "Run \(tool.title) here, through the proxy") {
                            run(tool, in: session)
                        }
                    }
                }
                if isHovering {
                    TileButton(symbol: "xmark", size: 20, help: "Close") { workspace.close(tabID: tab.id) }
                }
            }
        }
        .padding(.leading, 14)
        .sidebarRow(hovering: isHovering, selected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { workspace.selection = tab.id }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
    }

    /// An SSH tab's bandwidth, while there is some to speak of: an idle
    /// session only trickles keepalives, and a row of zeros is noise.
    private var bandwidth: String? {
        guard let rate = session?.rate, session?.isDisconnected != true,
              rate.bytesInPerSecond + rate.bytesOutPerSecond >= 1024 else { return nil }
        return "\u{2193}\(ToolsSidebar.compact(rate.bytesInPerSecond)) "
            + "\u{2191}\(ToolsSidebar.compact(rate.bytesOutPerSecond))"
    }

    /// Lit only while the shell is proxied, local or SSH alike. An SSH
    /// shell's proxy is its server's tunnel back here, so it takes that
    /// tunnel's colour: green while it runs, and a warning when it has
    /// dropped, since the shell's exports then point at nothing.
    private func proxyColor(_ session: TerminalSession) -> Color? {
        guard session.usesProxy else { return nil }
        guard let id = session.serverID, let preset = model.forwards.proxyBack(for: id) else { return theme.ansi(12) }
        return model.forwards.status(of: preset).color(stopped: theme.failing)
    }

    /// Its own shell through the proxy: this Mac's for a local one, the
    /// server's tunnel back here for an SSH one.
    private func toggleProxy(_ session: TerminalSession) {
        if session.isLocal {
            model.localProxy.toggle(session)
        } else if let id = session.serverID {
            Task { await model.toggleProxy(for: session, serverID: id) }
        }
    }

    /// Runs a coding agent in the shell, where it is, through the proxy: the
    /// shell is put through it first when it is not already, and the command
    /// typed after, at the same prompt. Refused with a beep while a program
    /// has the terminal.
    private func run(_ tool: AgentTool, in session: TerminalSession) {
        Task {
            guard await session.isAtPrompt() else { NSSound.beep(); return }
            if !session.usesProxy {
                if session.isLocal {
                    await model.localProxy.set(true, in: session)
                } else if let id = session.serverID {
                    await model.toggleProxy(for: session, serverID: id)
                }
                guard session.usesProxy else { return }
            }
            _ = await session.typeAtPrompt(tool.command)
        }
    }
}
