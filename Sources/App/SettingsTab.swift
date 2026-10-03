import Core
import SSH
import SwiftUI
import VT

/// Settings, as a tab rather than a window or a panel.
///
/// It sits beside the terminals because that is where there is room to read it,
/// and because closing it is the same gesture as closing anything else.
struct SettingsTab: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    let workspace: Workspace
    @State private var credentialCount = 0
    @State private var prunedMessage: String?
    @State private var proxyPort = ProxyEnvironment.defaultLocalPort
    @State private var proxySocksPort = ProxyEnvironment.defaultSocksLocalPort

    var body: some View {
        @Bindable var theme = theme
        @Bindable var environment = model.shellEnvironment
        VStack(alignment: .leading, spacing: 0) {
            // The page's own title, as System Settings heads each pane.
            Text(page.title)
                .font(.system(size: 30, weight: .bold))
                .padding(.horizontal, 40)
                .padding(.top, 48)
                .padding(.bottom, 20)
            // One rounded plate per section, labels on the left and controls
            // lined up on the right -- the grouped form's look, across the
            // whole pane rather than its fixed 700pt column.
            Form {
                switch page {
                case .general:
                    GeneralSettings(model: model)
                case .vpn:
                    VPNSettings(model: model)
                case .proxy:
                    Section("This Mac") {
                        // Where the proxy on this Mac (Surge, Clash) listens. Servers'
                        // proxy tunnels and local terminals both arrive here.
                        // SOCKS5 is 0 when there is none to use.
                        LabeledContent("HTTP port") { portField($proxyPort) }
                        LabeledContent("SOCKS5 port") { portField($proxySocksPort) }
                        .onChange(of: proxyPort) { Task { await model.setProxyPort(proxyPort) } }
                        .onChange(of: proxySocksPort) {
                            Task { await model.setProxySocksPort(proxySocksPort) }
                        }
                    }
                    .task {
                        proxyPort = model.forwards.proxyLocalPort
                        proxySocksPort = model.forwards.proxySocksLocalPort
                    }
                    ProxyTraffic(model: model)
                case .connections:
                    ConnectionsSettings(model: model, workspace: workspace)
                case .sshConfig:
                    SSHConfigSettings(model: model, workspace: workspace)
                case .claude, .codex:
                    AgentSettings(tool: page == .claude ? .claude : .codex, model: model,
                                  workspace: workspace)
                case .security:
                    Section("Unlock") {
                        // Off by default: the vault opens by itself. On, the
                        // Mac confirms the owner each time Termther opens.
                        if let methods = model.quickUnlockMethods {
                            Toggle("Require \(methods)", isOn: Binding(
                                get: { model.requiresMacUnlock },
                                set: { wanted in
                                    Task { _ = await model.setRequiresMacUnlock(wanted) }
                                }))
                        } else {
                            LabeledContent("Unlock with this Mac", value: "Not available")
                        }
                    }
                    Section("Credentials") {
                        LabeledContent("Keys and passwords") {
                            HStack(spacing: 10) {
                                Text(prunedMessage ?? "\(credentialCount)")
                                    .foregroundStyle(theme.secondaryText)
                                Button("Remove Unused") {
                                    Task {
                                        let removed = await model.pruneUnusedCredentials()
                                        prunedMessage = removed == 0 ? "Nothing to remove"
                                            : "Removed \(removed)"
                                        credentialCount = await model.credentialCount()
                                    }
                                }
                            }
                        }
                    }
                    .task { credentialCount = await model.credentialCount() }
                case .about:
                    Section {
                        // Each part by its own name and its version number.
                        LabeledContent("Termther", value: model.version)
                        LabeledContent("libghostty-vt", value: Terminal.libraryVersion)
                        LabeledContent("libssh2", value: model.libssh2Version)
                    }
                }
            }
            .modifier(SettingsFormStyle())
            // Every value shown -- versions, addresses, routes -- can be
            // selected and copied, as in System Settings.
            .textSelection(.enabled)
        }
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
        // Every server is connected to and read for as long as the
        // Connections page is showing. Decided here, from the page, rather
        // than by that section's own appearance: the form rebuilds its
        // sections as the figures change, and each rebuild let go of the
        // sessions and dialled again.
        .onChange(of: page == .connections, initial: true) { _, showing in
            model.monitor.watch(all: showing)
        }
        .onDisappear { model.monitor.watch(all: false) }
    }

    private var page: SettingsPage { workspace.settingsPage }

    /// A port, plain and at the row's end like every other field here.
    private func portField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never))
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 80)
    }
}

/// The pages of Settings, listed in the sidebar while Settings is open.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, connections, sshConfig, vpn, proxy, claude, codex, security, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general:   "General"
        case .vpn:       "VPN"
        case .proxy:     "Proxy"
        case .connections: "Connections"
        case .sshConfig: "SSH Config"
        case .claude:    AgentTool.claude.title
        case .codex:     AgentTool.codex.title
        case .security:  "Security"
        case .about:     "About"
        }
    }

    /// An agent's own mark, in place of a symbol.
    var logo: Image? {
        switch self {
        case .claude: AgentTool.claude.logo
        case .codex:  AgentTool.codex.logo
        default:      nil
        }
    }

    var icon: String {
        switch self {
        case .general:   "gearshape"
        case .vpn:       "network.badge.shield.half.filled"
        case .proxy:     "arrow.triangle.swap"
        case .connections: "server.rack"
        case .sshConfig: "doc.text"
        case .claude:    "sparkles"
        case .codex:     "cpu"
        case .security:  "lock"
        case .about:     "info.circle"
        }
    }
}

/// Each server sending its traffic back through this Mac, with what its
/// tunnel is carrying: live bandwidth, the totals, and open connections.
/// Sampled once a second by `Forwards`, so it updates as it is watched.
private struct ProxyTraffic: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel

    private var forwards: Forwards { model.forwards }

    /// One entry per server: its HTTP and SOCKS5 halves are one proxy to
    /// whoever is using it, so they are read together.
    private var entries: [(server: Server, presets: [PortForwardPreset])] {
        model.servers.compactMap { server in
            let presets = forwards.proxyPresets.filter { $0.serverID == server.id }
            return presets.isEmpty ? nil : (server, presets)
        }
    }

    var body: some View {
        Section("Traffic") {
            if entries.isEmpty {
                Text("No proxied servers")
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(entries, id: \.server.id) { entry in
                row(entry.server, entry.presets)
            }
        }
    }

    private func row(_ server: Server, _ presets: [PortForwardPreset]) -> some View {
        let status = combined(presets.map(forwards.status(of:)))
        let ids = presets.compactMap(\.id)
        let all = ids.compactMap { forwards.traffic[$0] }
        let stats = all.isEmpty ? nil : (bytesIn: all.reduce(0) { $0 + $1.bytesIn },
                                         bytesOut: all.reduce(0) { $0 + $1.bytesOut },
                                         connections: all.reduce(0) { $0 + $1.connections })
        let rates = ids.compactMap { forwards.rates[$0] }
        return HStack(spacing: 10) {
            Circle()
                .fill(status.color(stopped: theme.secondaryText.opacity(0.5)))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName)
                Text(totals(status, stats))
                    .font(theme.ui(12))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            if status == .running {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\u{2193} " + perSecond(rates.reduce(0) { $0 + $1.bytesInPerSecond }))
                    Text("\u{2191} " + perSecond(rates.reduce(0) { $0 + $1.bytesOutPerSecond }))
                }
                .font(theme.ui(13))
                .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }

    /// The halves as one: whichever needs attention, else running if either is.
    private func combined(_ statuses: [Forwards.Status]) -> Forwards.Status {
        statuses.first { if case .failed = $0 { true } else { false } }
            ?? statuses.first { if case .retrying = $0 { true } else { false } }
            ?? (statuses.contains(.starting) ? .starting : nil)
            ?? (statuses.contains(.running) ? .running : .stopped)
    }

    private func totals(_ status: Forwards.Status,
                        _ stats: (bytesIn: UInt64, bytesOut: UInt64, connections: Int)?) -> String {
        switch status {
        case .running:
            guard let stats else { return "connected" }
            return "\(bytes(stats.bytesIn)) in \u{00B7} \(bytes(stats.bytesOut)) out \u{00B7} "
                + (stats.connections == 1 ? "1 connection" : "\(stats.connections) connections")
        case .starting:            return "connecting\u{2026}"
        case .retrying(let why):   return why
        case .failed(let why):     return why
        case .stopped:             return "not running"
        }
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.numeric(Int64(count), countStyle: .binary)
    }

    private func perSecond(_ rate: Double) -> String {
        ByteCountFormatter.numeric(Int64(rate), countStyle: .binary) + "/s"
    }
}

/// A slider for the multipliers that shape the grid.
struct Multiplier: View {
    @Environment(Theme.self) private var theme
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: 0.05)
                    .frame(width: 180)
                Text(String(format: "%.2f×", value))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}

/// The wide form where it can be built, the system's grouped one before
/// macOS 15.
private struct SettingsFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.formStyle(WideFormStyle())
        } else {
            content.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

/// Settings' form: sections as rounded plates the width of the pane, with
/// room between rows and between sections.
@available(macOS 15, *)
struct WideFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if !section.header.isEmpty {
                            section.header
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 4)
                        }
                        if section.containerValues.isBare {
                            section.content
                        } else if !section.content.isEmpty {
                            Plate { section.content }
                        }
                    }
                }
            }
            // The page title's margin.
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .labeledContentStyle(RowLabeledContentStyle())
        .toggleStyle(RowToggleStyle())
    }

    /// One section's rows, separated by hairlines.
    private struct Plate<Content: View>: View {
        @Environment(Theme.self) private var theme
        @ViewBuilder var content: Content

        var body: some View {
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { Divider().padding(.leading, 18) }
                        rows[index]
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 4)
                    }
                }
            }
            .background(theme.text.opacity(0.05), in: .rect(cornerRadius: 12))
        }
    }
}

/// A section laid out on the page itself, with no plate: one whose content
/// is cards of its own.
@available(macOS 15, *)
private struct BareSectionKey: ContainerValueKey {
    static let defaultValue = false
}

@available(macOS 15, *)
extension ContainerValues {
    var isBare: Bool {
        get { self[BareSectionKey.self] }
        set { self[BareSectionKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func bareSection() -> some View {
        if #available(macOS 15, *) { containerValue(\.isBare, true) } else { self }
    }
}

/// Label on the left, content on the right, as a form row.
struct RowLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
            Spacer(minLength: 16)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A switch at the end of the row, its label at the start.
struct RowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
            Spacer(minLength: 16)
            Toggle(configuration).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

/// A text field as a form row: its name on the left, the text on the right,
/// the way a grouped form lays out a labelled field.
struct FieldRow: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    var isSecure = false

    var body: some View {
        LabeledContent(title) {
            Group {
                if isSecure {
                    SecureField("", text: $text, prompt: prompt.map { Text($0) })
                } else {
                    TextField("", text: $text, prompt: prompt.map { Text($0) })
                }
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.primary)
        }
    }
}

/// A section title that folds the section away, with a chevron saying so.
struct FoldHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
