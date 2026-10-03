import AppKit
import Core
import SwiftUI

/// The Connections page: every server as a card, with what it is doing.
///
/// Edited through the same editor as the sidebar's; what `~/.ssh/config`
/// has besides is the SSH Config page's.
struct ConnectionsSettings: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    let workspace: Workspace
    @State private var editing: Server?
    @State private var confirmingDeletion: Server?
    @State private var importing = false

    var body: some View {
        Section {
            // Cards rather than rows: each carries the server's load, which
            // is several figures, and a row has room for one.
            if model.servers.isEmpty {
                Text("No connections")
                    .foregroundStyle(theme.secondaryText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    ForEach(model.servers) { server in
                        ConnectionCard(server: server, monitor: model.monitor,
                                       needsTunnel: model.needsTunnel(server),
                                       edit: { editing = server },
                                       connect: { workspace.open(server, using: model) })
                            .contextMenu {
                                Button("Connect") { workspace.open(server, using: model) }
                                Button("Edit\u{2026}") { editing = server }
                                Divider()
                                Button("Delete\u{2026}", role: .destructive) { confirmingDeletion = server }
                            }
                    }
                }
            }
        } header: {
            HStack {
                Text("Connections")
                Spacer()
                // One +, for both ways a connection arrives: made here, or
                // brought in from ~/.ssh/config or another such file.
                SwiftUI.Menu {
                    Button("New Connection\u{2026}") { editing = Server(name: "", host: "", username: "") }
                    Button("Import from SSH Config\u{2026}") { importing = true }
                } label: {
                    Image(systemName: "plus").font(.headerPlus)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add Connection")
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
    }
}

/// One server: its name, address and whether it answered; CPU, memory and
/// each GPU and disk as gauges, three to a row; uptime as a line under them.
///
/// A click connects, as a click on a Connect button does; the pencil, shown
/// on hover, and the menu open the editor. Not the sidebar's double-click:
/// that row only has one because a single tap would make its buttons wait
/// out the double-click interval, and a card has no buttons but the pencil.
private struct ConnectionCard: View {
    @Environment(Theme.self) private var theme
    let server: Server
    let monitor: ServerMonitor
    /// True when the server is behind the VPN and the VPN is down: said in
    /// so many words rather than as a failure, since it was never tried.
    let needsTunnel: Bool
    let edit: () -> Void
    let connect: () -> Void
    @State private var isHovering = false

    private var load: ServerLoad? { server.id.flatMap { monitor.loads[$0] } }
    private var error: String? { server.id.flatMap { monitor.errors[$0] } }
    private var status: Color {
        error != nil ? .red : load != nil ? .green : theme.secondaryText.opacity(0.4)
    }

    /// The gauges, three to a row so the columns line up card to card.
    private var gauges: [(label: String, value: String, share: Double)] {
        guard let load else { return [] }
        var gauges: [(label: String, value: String, share: Double)] = []
        if let cpu = load.cpuPercent { gauges.append(("CPU", percent(cpu), cpu)) }
        if let used = load.memoryUsed, let total = load.memoryTotal, let share = load.memoryPercent {
            gauges.append(("Memory", "\(gigabytes(used, total)) GB", share))
        }
        for (index, gpu) in load.gpus.enumerated() {
            gauges.append((load.gpus.count == 1 ? "GPU" : "GPU \(index)",
                           percent(gpu.utilizationPercent), gpu.utilizationPercent ?? 0))
        }
        if let disk = load.diskUsedPercent { gauges.append(("Disk", percent(disk), disk)) }
        return gauges
    }

    private var footer: String {
        load?.uptime.map { "Up \(ServerLoad.uptime($0))" } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(server.displayName)
                    .font(theme.ui(15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if isHovering {
                    Button(action: edit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit")
                }
                // Green once it has answered, red with the reason on hover,
                // grey until the first answer; a faint halo, as a status
                // light has.
                Circle()
                    .fill(status)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill(status.opacity(0.25)).padding(-3))
                    .help(error ?? "")
            }
            Text("\(server.username)@\(server.host):\(server.port)"
                 + (needsTunnel ? " \u{00B7} VPN off" : ""))
                .font(theme.ui(12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .padding(.top, 3)
            let gauges = gauges
            if !gauges.isEmpty {
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 16) {
                    ForEach(Array(stride(from: 0, to: gauges.count, by: 3)), id: \.self) { start in
                        GridRow {
                            ForEach(start..<min(start + 3, gauges.count), id: \.self) { index in
                                gauge(gauges[index])
                            }
                        }
                    }
                }
                .padding(.top, 18)
            } else if error == nil, !needsTunnel {
                Text("Connecting\u{2026}")
                    .font(theme.ui(12))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 18)
            }
            if !footer.isEmpty {
                Divider().padding(.top, 16)
                Text(footer)
                    .font(theme.ui(12))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                    .padding(.top, 10)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(theme.text.opacity(isHovering ? 0.07 : 0.045), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.border.opacity(isHovering ? 1.6 : 1)))
        .contentShape(.rect(cornerRadius: 14))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: connect)
        .animation(.easeOut(duration: 0.3), value: load)
    }

    /// A small label, the figure under it, and a hairline filled to the
    /// share -- orange past 75%, red past 90%. Each takes a third of the
    /// card, so the columns line up from one card to the next.
    private func gauge(_ gauge: (label: String, value: String, share: Double)) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(gauge.label)
                .font(theme.ui(11))
                .foregroundStyle(theme.secondaryText)
            Text(gauge.value)
                .font(theme.ui(15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.text.opacity(0.08))
                    Capsule()
                        .fill(gauge.share > 90 ? .red : gauge.share > 75 ? .orange : theme.accent)
                        .frame(width: geometry.size.width * min(max(gauge.share, 0), 100) / 100)
                }
            }
            .frame(height: 4)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "\u{2013}"
    }

    /// "18.0/24.0", so the two read as one figure with one unit after it.
    private func gigabytes(_ used: UInt64, _ total: UInt64) -> String {
        "\(ServerLoad.gigabytes(used))/\(ServerLoad.gigabytes(total))"
    }
}
