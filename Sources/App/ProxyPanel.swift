import Core
import SwiftUI

/// The servers whose own traffic comes back through this Mac.
///
/// A reverse tunnel underneath, but that is not what it is for: the point is
/// "this machine's curl, git and pip go out through my proxy", and a list of
/// ports would not say that. The tunnel is the mechanism; this is the feature.
struct ProxyPanel: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel

    @State private var editing: PortForwardPreset?
    @State private var isEditingPort = false
    @State private var draftPort = ProxyEnvironment.defaultLocalPort

    private var forwards: Forwards { model.forwards }

    /// Each proxied server, with the tunnel carrying it.
    private var entries: [(server: Server, preset: PortForwardPreset)] {
        forwards.proxyPresets.compactMap { preset in
            guard let server = model.servers.first(where: { $0.id == preset.serverId })
            else { return nil }
            return (server, preset)
        }
    }

    private var available: [Server] {
        model.servers.filter { server in
            guard let id = server.id else { return false }
            return forwards.proxyBack(for: id) == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            List {
                ForEach(entries, id: \.preset.id) { entry in
                    ProxyRow(server: entry.server, preset: entry.preset,
                             forwards: forwards, edit: { editing = entry.preset })
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if entries.isEmpty { empty }
            }
        }
        .sheet(item: $editing) { preset in
            ProxyEditor(model: model, preset: preset)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 0) {
                addButton
                Spacer(minLength: 8)
            }
            .padding(.horizontal, SidePanel.inset)
            .padding(.vertical, 6)
        }
    }

    /// Where the proxy on this Mac is. One line, because it is one fact about
    /// this machine rather than a setting per server.
    private var header: some View {
        HStack(spacing: 6) {
            if isEditingPort {
                Text("127.0.0.1:")
                    .font(theme.ui(11))
                    .foregroundStyle(theme.secondaryText)
                TextField("", value: $draftPort, format: .number.grouping(.never))
                    .textFieldStyle(.plain)
                    .font(theme.ui(11))
                    .frame(width: 48)
                    .onSubmit { commitPort() }
                Button("Set") { commitPort() }
                    .buttonStyle(.plain)
                    .font(theme.ui(11))
                    .foregroundStyle(theme.accent)
            } else {
                // String(), not interpolation into Text: SwiftUI formats an
                // interpolated Int with the locale's number style, and a port
                // written "6,152" is not a port.
                Text("Proxy on 127.0.0.1:" + String(forwards.proxyLocalPort))
                    .font(theme.ui(11))
                    .foregroundStyle(theme.secondaryText)
                Button {
                    draftPort = forwards.proxyLocalPort
                    isEditingPort = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("Surge listens on 6152 by default")
            }
            Spacer()
        }
        .padding(.horizontal, SidePanel.inset)
        .padding(.bottom, 8)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing proxied", systemImage: "arrow.uturn.left")
        } description: {
            // No button here: Add Proxy is in the bar below, and two of them
            // is one too many.
            Text("Add a server here and its commands go out through the proxy "
                 + "running on this Mac.")
        }
    }

    private var addButton: some View {
        Button {
            editing = blank
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 15, height: 15)
                Text("Add Proxy")
            }
            .font(theme.ui(12))
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.secondaryText)
        .disabled(available.isEmpty)
    }

    /// A new one: started by hand, supervised once started.
    ///
    /// Not automatic. Coming up on its own means dialling a server the moment
    /// the vault opens, which is a connection nobody asked for. Staying up is
    /// different -- a tunnel that drops while in use takes the server's whole
    /// route out with it -- so that half is on.
    private var blank: PortForwardPreset {
        PortForwardPreset(serverId: available.first?.id ?? 0, direction: .remote,
                          bindPort: ProxyEnvironment.defaultRemotePort,
                          targetHost: "127.0.0.1",
                          targetPort: forwards.proxyLocalPort,
                          autoStart: false, keepAlive: true, exportsEnvironment: true)
    }

    private func commitPort() {
        isEditingPort = false
        Task { await forwards.setProxyLocalPort(draftPort) }
    }
}

private struct ProxyRow: View {
    @Environment(Theme.self) private var theme
    let server: Server
    let preset: PortForwardPreset
    @Bindable var forwards: Forwards
    let edit: () -> Void

    @State private var isHovering = false

    private var status: Forwards.Status { forwards.status(of: preset) }

    var body: some View {
        HStack(spacing: 8) {
            // A light, not a button: the switch on the right is the control,
            // and two things doing the same job is how you end up unsure
            // which one you just used.
            Circle()
                .fill(indicator)
                .frame(width: 8, height: 8)
                .frame(width: 14, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name.isEmpty ? server.host : server.name)
                    .font(theme.ui(13))
                    .lineLimit(1)
                Text(detail)
                    .font(theme.ui(11))
                    .foregroundStyle(detailColour)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: edit)

            if isHovering {
                Button(action: edit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("Edit")

                Button {
                    Task { await forwards.setProxyBack(false, for: server.id ?? 0, remotePort: 0) }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("Stop routing this server through this Mac")
            }

            Toggle("", isOn: Binding(
                get: { status.isLive },
                set: { wanted in
                    Task {
                        if wanted { await forwards.start(preset) }
                        else if let id = preset.id { await forwards.stop(id) }
                    }
                }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(status.isLive ? "Stop the tunnel" : "Start the tunnel")
        }
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
    }

    /// Traffic while it is up, the reason while it is not.
    private var detail: String {
        switch status {
        case .running:
            guard let id = preset.id, let stats = forwards.traffic[id] else {
                return "port \(preset.bindPort) on the server"
            }
            return "\(bytes(stats.bytesIn)) in  \(bytes(stats.bytesOut)) out"
        case .starting:            return "connecting\u{2026}"
        case .retrying(let why):   return why
        case .failed(let why):     return why
        case .stopped:             return "not running"
        }
    }

    private var detailColour: Color {
        switch status {
        case .failed:   .orange
        case .retrying: .yellow
        default:        theme.secondaryText
        }
    }

    private var indicator: Color {
        switch status {
        case .running:              .green
        case .starting, .retrying:  .yellow
        case .failed:               .orange
        case .stopped:              theme.secondaryText.opacity(0.5)
        }
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
}
