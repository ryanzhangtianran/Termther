import Core
import EC
import SwiftUI

/// The tunnel.
///
/// One gateway, not a list: the engine holds process-global state and can only
/// carry one tunnel at a time. The panel is arranged in the order the
/// questions come -- is it up, what is it for, what will it carry -- with the
/// last of those folded away, because it is long and only wanted when
/// something has gone missing.
struct VPNPanel: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel

    @State private var editing: VPNProfile?
    @State private var showsRoutes = false

    private var vpn: VPNController { model.vpn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let profile = vpn.profile {
                    gateway(profile)
                    divider
                    servers
                    if vpn.state.isOn, let routing = vpn.routing, !routing.isEmpty {
                        divider
                        routes(routing)
                    }
                } else {
                    empty
                }
            }
            .padding(.horizontal, SidePanel.inset)
            .padding(.bottom, 10)
        }
        .sheet(item: $editing) { profile in
            VPNEditor(model: model, profile: profile)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
            .padding(.vertical, 10)
    }

    // MARK: - the gateway

    private func gateway(_ profile: VPNProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicator)
                    .frame(width: 8, height: 8)

                Text(profile.name.isEmpty ? profile.gateway : profile.name)
                    .font(theme.ui(13, weight: .medium))
                    .lineLimit(1)

                // At the top and always visible: there is one gateway, so
                // hiding its editor behind a hover is hiding the only thing
                // in the panel you might want to change.
                Button { editing = profile } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("Edit gateway")

                Spacer(minLength: 6)

                Toggle("", isOn: Binding(
                    get: { vpn.state.isOn },
                    set: { wanted in
                        Task {
                            if wanted { await vpn.connect(profile) }
                            else { await vpn.disconnect() }
                        }
                    }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(vpn.state == .connecting)
            }

            Text("\(profile.username)@\(profile.gateway)")
                .font(theme.ui(11))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)

            Text(headline)
                .font(theme.ui(11))
                .foregroundStyle(headlineColour)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // Which interface and resolver the engine is really using. A wrong
            // underlay fails as a timeout that blames the gateway, and nothing
            // on screen used to contradict it.
            if let underlay = vpn.underlayDescription {
                Text("via \(underlay)\(uptime)")
                    .font(theme.ui(10))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.top, 2)
    }

    private var uptime: String {
        guard let since = vpn.connectedAt else { return "" }
        let seconds = Int(Date().timeIntervalSince(since))
        if seconds < 60 { return " \u{00B7} up \(seconds)s" }
        if seconds < 3600 { return " \u{00B7} up \(seconds / 60)m" }
        return " \u{00B7} up \(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    // MARK: - who it is for

    private var servers: some View {
        VStack(alignment: .leading, spacing: 4) {
            title("Servers through it")
            if model.servers.isEmpty {
                Text("No servers yet.")
                    .font(theme.ui(11))
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(model.servers) { server in
                Button {
                    Task { await model.setRoutesThroughVPN(!server.routesThroughVPN, for: server) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: server.routesThroughVPN
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(server.routesThroughVPN
                                             ? theme.accent : theme.secondaryText)
                        Text(server.name.isEmpty ? server.host : server.name)
                            .font(theme.ui(11))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(server.host)
                            .font(theme.ui(10))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(height: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - what it carries

    /// Folded away, and worth having: the gateway drops traffic to anything
    /// outside this list rather than refusing it, so a host missing here looks
    /// exactly like a hang.
    private func routes(_ routing: EasyConnect.Routing) -> some View {
        DisclosureGroup(isExpanded: $showsRoutes) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(routing.ip) { range in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(range.addresses)
                            .font(theme.mono(10))
                            .textSelection(.enabled)
                        Text("\(range.ports) \u{00B7} \(range.protocolName)")
                            .font(theme.ui(10))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !routing.dns.isEmpty {
                    labelled("DNS", routing.dns.joined(separator: ", "))
                }
                if !routing.domains.isEmpty {
                    labelled("Domains", routing.domains.prefix(8).joined(separator: ", ")
                             + (routing.domains.count > 8 ? "\u{2026}" : ""))
                }
            }
            .padding(.top, 5)
        } label: {
            HStack(spacing: 4) {
                title("What it routes")
                Text(String(routing.ip.count))
                    .font(theme.ui(9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(.automatic)
    }

    private func labelled(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .font(theme.ui(9, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(theme.mono(10))
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ text: String) -> some View {
        Text(text.uppercased())
            .font(theme.ui(9, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No gateway")
                .font(theme.ui(12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Text("Add an EasyConnect gateway to reach hosts behind its firewall. "
                 + "One is all there is: the engine carries a single tunnel.")
                .font(theme.ui(11))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Gateway") { editing = blank }
                .buttonStyle(.plain)
                .font(theme.ui(12))
                .foregroundStyle(theme.accent)
                .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private var headline: String {
        switch vpn.state {
        case .off:                  "Not connected"
        case .connecting:           "Connecting\u{2026}"
        case .on(let address):      "Connected as \(address)"
        case .failed(let reason):   reason
        }
    }

    private var headlineColour: Color {
        if case .failed = vpn.state { return .orange }
        return theme.secondaryText
    }

    private var indicator: Color {
        switch vpn.state {
        case .on:         .green
        case .connecting: .yellow
        case .failed:     .orange
        case .off:        theme.secondaryText.opacity(0.5)
        }
    }

    private var blank: VPNProfile {
        VPNProfile(name: "", gateway: "", username: "",
                   sealed: .init(ciphertext: Data(), nonce: Data()))
    }
}
