import AppKit
import Core
import SwiftUI

/// The Connections page: a monitor of every server.
///
/// What needs doing something about comes first, each with the one button
/// that does it; the servers that answer follow as a table whose columns
/// line up from row to row. Edited through the same editor as the sidebar's;
/// what `~/.ssh/config` has besides is the SSH Config page's.
struct ConnectionsSettings: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    let workspace: Workspace
    @State private var editing: Server?
    @State private var confirmingDeletion: Server?
    @State private var importing = false

    private var monitor: ServerMonitor { model.monitor }

    private func error(_ server: Server) -> String? { server.id.flatMap { monitor.errors[$0] } }

    /// Failing, or behind a VPN that is down.
    private var attention: [Server] {
        model.servers.filter { error($0) != nil || model.needsTunnel($0) }
    }
    private var answering: [Server] {
        model.servers.filter { error($0) == nil && !model.needsTunnel($0) }
    }

    var body: some View {
        // Worked out once a render, not once a row: the page is redrawn
        // with every probe.
        let attention = self.attention
        let firstAttention = attention.first?.id
        let answering = self.answering
        // Whether any card shows a row of GPU bars; the others keep the
        // room, so the cards stay one height.
        let hasGPURow = answering.contains { ($0.id.flatMap { monitor.loads[$0] }?.gpus.count ?? 0) > 1 }
        Section {
            summary
            if model.servers.isEmpty {
                Text("No connections")
                    .font(theme.ui(13, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .plate()
            }
        }
        .bareSection()
        .sheet(item: $editing) { server in
            ServerEditor(model: model, server: server)
        }
        .sheet(isPresented: $importing) {
            ImportList(model: model, onFinished: { importing = false })
                .frame(width: 470, height: 540)
        }
        .alert(item: $confirmingDeletion) { server in
            Alert(title: Text("Delete \u{201C}\(server.displayName)\u{201D}?"),
                  message: Text("Its port forwards are deleted too."),
                  primaryButton: .destructive(Text("Delete")) { Task { await model.delete(server) } },
                  secondaryButton: .cancel())
        }

        if !attention.isEmpty {
            Section("Needs Attention") {
                VStack(spacing: 0) {
                    ForEach(attention) { server in
                        if server.id != firstAttention { Divider().opacity(0.5).padding(.horizontal, 18) }
                        attentionRow(server)
                    }
                }
                .padding(.vertical, 2)
                .plate()
            }
            .bareSection()
        }

        if !answering.isEmpty {
            Section("Online") {
                // Three across, sharing the width: a wider window makes the
                // cards larger, not more numerous, and what is in them grows
                // with them. Each the same height, GPUs or not.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3),
                          spacing: 14) {
                    ForEach(answering) { server in
                        MonitorCard(server: server, monitor: monitor, reservesGPURow: hasGPURow,
                                    connect: { workspace.open(server, using: model) },
                                    edit: { editing = server },
                                    delete: { confirmingDeletion = server })
                    }
                }
            }
            .bareSection()
        }
    }

    /// How many are up, failing and waiting, and the two ways a server
    /// arrives: made here, or brought in from ~/.ssh/config.
    private var summary: some View {
        let failing = model.servers.filter { error($0) != nil }.count
        let waiting = model.servers.filter { error($0) == nil && model.needsTunnel($0) }.count
        let online = answering.filter { $0.id.map { monitor.loads[$0] != nil } ?? false }.count
        return HStack(spacing: 10) {
            stat(online, "Online", theme.online)
            if failing > 0 { stat(failing, "Failed", theme.failing) }
            if waiting > 0 { stat(waiting, "Waiting for VPN", theme.waiting) }
            Spacer()
            Button("Import from SSH Config") { importing = true }
                .buttonStyle(.plate)
            Button("Add Server") { editing = Server(name: "", host: "", username: "") }
                .buttonStyle(.plateProminent)
        }
    }

    private func stat(_ count: Int, _ title: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(count)")
                .font(theme.ui(20, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .font(theme.ui(12, weight: .regular))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(theme.text.opacity(0.045), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func attentionRow(_ server: Server) -> some View {
        let failure = error(server)
        return HStack(spacing: 12) {
            Tile(symbol: "server.rack", light: failure != nil ? theme.failing : nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName)
                Text(failure ?? "Behind the VPN, which is not connected")
                    .font(theme.ui(12, weight: .regular))
                    .foregroundStyle(failure != nil ? theme.failing : theme.waiting)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if failure != nil {
                Button("Edit") { editing = server }
                    .buttonStyle(.plate)
            } else if let profile = model.vpn.profile {
                Button("Connect VPN") { Task { await model.vpn.connect(profile) } }
                    .buttonStyle(.plateProminent)
                    .disabled(model.vpn.state == .connecting)
            }
            TileButton(symbol: "trash", help: "Delete") { confirmingDeletion = server }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

/// One answering server as a card: CPU, memory, disk -- and the GPUs'
/// average -- as rings, a bar for each GPU under them, and the last ten
/// minutes of CPU along the bottom. Type stays one size whatever the
/// window: a wider card gives the graph more room. Before the first reading the card has the same shape, empty, so
/// the row stays even. Uptime, load and the address are on hover.
private struct MonitorCard: View {
    @Environment(Theme.self) private var theme
    let server: Server
    let monitor: ServerMonitor
    let reservesGPURow: Bool
    let connect: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    static let ringSize: CGFloat = 50
    static let barHeight: CGFloat = 24

    private var load: ServerLoad? { server.id.flatMap { monitor.loads[$0] } }
    private var history: [Double] { server.id.flatMap { monitor.history[$0] } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Tile(symbol: server.jumpHostID == nil ? "server.rack" : "arrow.triangle.branch",
                     light: load != nil ? theme.online : nil)
                Text(server.displayName)
                    .lineLimit(1)
                    .help(details)
                Spacer(minLength: 0)
                // What a card is for, on the card rather than behind a
                // right click.
                if isHovering {
                    HStack(spacing: 2) {
                        TileButton(symbol: "apple.terminal", color: theme.ansi(12),
                                   help: "Connect", action: connect)
                        TileButton(symbol: "pencil", help: "Edit", action: edit)
                        TileButton(symbol: "trash", help: "Delete", action: delete)
                    }
                    .transition(.opacity)
                } else if load == nil {
                    Chip(title: "Connecting", color: theme.waiting)
                }
            }
            .frame(height: 24)

            rings.frame(maxWidth: .infinity)
            // The GPUs one by one, under the rings; a card without them
            // gives the room to its graph, so a row of cards stays even.
            if let load, load.gpus.count > 1 {
                gpuBars(load.gpus).frame(maxWidth: .infinity)
            }
            let hasBars = (load?.gpus.count ?? 0) > 1
            graph.frame(height: 30 + (reservesGPURow && !hasBars ? Self.barHeight + 14 : 0))
        }
        .padding(16)
        .plate()
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
        .animation(.easeOut(duration: 0.3), value: load)
    }

    private var rings: some View {
        HStack(alignment: .top, spacing: 14) {
            ring(load?.cpuPercent, "CPU")
            ring(load?.memoryPercent, "Memory")
            ring(load?.diskUsedPercent, "Disk")
            if let gpus = load?.gpus, !gpus.isEmpty {
                ring(average(gpus), gpus.count == 1 ? "GPU" : "GPU \u{00D7}\(gpus.count)")
            }
        }
        .fixedSize()
    }

    /// The last ten minutes of CPU, scaled to what it reaches so a quiet
    /// server still shows its shape; a dashed line until there are two
    /// readings to join.
    @ViewBuilder
    private var graph: some View {
        if load != nil, history.count > 1 {
            Sparkline(values: history, color: level(load?.cpuPercent ?? 0),
                      ceiling: max(10, (history.max() ?? 0) * 1.4))
                .help("CPU over the last ten minutes")
        } else {
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height - 2))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height - 2))
                }
                .stroke(theme.text.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            }
        }
    }

    private var details: String {
        var lines = ["\(server.username)@\(server.host):\(server.port)"]
        // On hover, as in the sidebar: a lock on the name reads as locked.
        if server.routesThroughVPN { lines.append("Through the VPN") }
        if let uptime = load?.uptime { lines.append("Up \(ServerLoad.uptime(uptime))") }
        if let load1 = load?.load1 { lines.append(String(format: "Load %.2f", load1)) }
        return lines.joined(separator: "\n")
    }

    private func average(_ gpus: [ServerLoad.GPU]) -> Double? {
        let known = gpus.compactMap(\.utilizationPercent)
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }

    /// A share as a ring with the figure in it and its name under it; an
    /// empty ring and a dash before there is a figure.
    private func ring(_ share: Double?, _ title: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(theme.text.opacity(0.08), lineWidth: 4.5)
                if let share {
                    Circle()
                        .trim(from: 0, to: min(max(share, 0), 100) / 100)
                        .stroke(level(share), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(share.map { "\(Int($0.rounded()))%" } ?? "\u{2013}")
                    .font(theme.ui(12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(share == nil ? theme.secondaryText : theme.text)
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            Text(title.uppercased())
                .font(theme.ui(9.5, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: Self.ringSize)
    }

    /// One bar per GPU, its height its use: eight cards fit as well as two,
    /// and a full one stands out. Each card's figures are on hover.
    private func gpuBars(_ gpus: [ServerLoad.GPU]) -> some View {
        HStack(alignment: .bottom, spacing: 9) {
            ForEach(gpus.indices, id: \.self) { index in
                let gpu = gpus[index]
                let share = gpu.utilizationPercent ?? 0
                Capsule()
                    .fill(theme.text.opacity(0.08))
                    .overlay(alignment: .bottom) {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(level(share))
                                .frame(height: max(geometry.size.width, geometry.size.height * min(share, 100) / 100))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .frame(width: 8)
                    .help(["GPU \(index)", gpu.utilizationPercent.map { "\(Int($0.rounded()))%" },
                           gpu.memoryUsed.flatMap { used in gpu.memoryTotal.map {
                               "\(ServerLoad.gigabytes(used))/\(ServerLoad.gigabytes($0)) GB" } }]
                        .compactMap { $0 }.joined(separator: " \u{00B7} "))
            }
        }
        .frame(height: Self.barHeight)
    }

    /// The scheme's blue, its yellow past 75%, its red past 90%.
    private func level(_ share: Double) -> Color {
        share > 90 ? theme.failing : share > 75 ? theme.waiting : theme.ansi(12)
    }
}
