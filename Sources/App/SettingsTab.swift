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
    @State private var proxyPort: Int?
    @State private var proxySocksPort: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The page's own title, as System Settings heads each pane.
            Text(page.title)
                .font(theme.ui(26, weight: .semibold))
                .padding(.horizontal, Self.margin)
                // Clear of the titlebar the pane runs up under.
                .padding(.top, 50)
                .padding(.bottom, 22)
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
                        // Empty is unset, with no default; SOCKS5 empty is none.
                        LabeledContent("HTTP Port") { portField($proxyPort) }
                        LabeledContent("SOCKS5 Port") { portField($proxySocksPort) }
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
                    SSHConfigSettings(model: model)
                case .claude, .codex:
                    AgentSettings(tool: page == .claude ? .claude : .codex, model: model,
                                  workspace: workspace)
                case .mcp:
                    MCPSettings(agents: model.agents)
                case .sessions:
                    SessionsSettings(agents: model.agents, workspace: workspace)
                case .about:
                    Section {
                        VStack(spacing: 6) {
                            // The app's own icon, as the Dock and Finder show it.
                            Image(nsImage: NSApp.applicationIconImage)
                                .resizable()
                                .frame(width: 96, height: 96)
                            Text("Termther")
                                .font(theme.ui(20, weight: .medium))
                                .padding(.top, 6)
                            Text(model.version)
                                .font(theme.ui(12.5, weight: .regular))
                                .monospacedDigit()
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .plate()
                    }
                    .bareSection()
                    Section("Components") {
                        // Each part by its own name and its version number.
                        LabeledContent("libghostty-vt", value: Terminal.libraryVersion)
                        LabeledContent("libssh2", value: model.libssh2Version)
                    }
                }
            }
            .modifier(SettingsFormStyle(page: page))
            // Every value shown -- versions, addresses, routes -- can be
            // selected and copied, as in System Settings.
            .textSelection(.enabled)
        }
        // A column, not the whole pane: lines that run the width of a wide
        // window are hard to read across. Wide enough to fill a laptop's
        // window, so the margins only grow on a large display.
        .frame(maxWidth: 1200)
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

    /// The page's side margin, shared by its title and its sections.
    static let margin: CGFloat = 48

    /// A port, plain and at the row's end like every other field here.
    private func portField(_ value: Binding<Int?>) -> some View {
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
    case general, connections, sshConfig, vpn, proxy, claude, codex, mcp, sessions, about

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
        case .mcp:       "MCP"
        case .sessions:  "Sessions"
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
        case .mcp:       "point.3.connected.trianglepath.dotted"
        case .sessions:  "clock.arrow.circlepath"
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
        let proxies = forwards.proxyPresets
        return model.servers.compactMap { server in
            let presets = proxies.filter { $0.serverID == server.id }
            return presets.isEmpty ? nil : (server, presets)
        }
    }

    /// Fixed widths, the room left over at the row's end rather than in
    /// the middle, where it pushed the figures far from their server --
    /// as the SSH Config hosts are laid out.
    enum Column {
        static let server: CGFloat = 180
        static let total: CGFloat = 220
        static let connections: CGFloat = 90
        static let rate: CGFloat = 90
        /// The light and its gap, so the Server title sits over the name.
        static let light: CGFloat = 15
    }

    var body: some View {
        let entries = self.entries
        Section("Traffic") {
            if entries.isEmpty {
                Text("No proxied servers")
                    .foregroundStyle(theme.secondaryText)
            } else {
                HStack(spacing: 16) {
                    Text("Server").padding(.leading, Column.light).frame(width: Column.server, alignment: .leading)
                    Text("Total").frame(width: Column.total, alignment: .leading)
                    Text("Connections").frame(width: Column.connections, alignment: .trailing)
                    Text("Down").frame(width: Column.rate, alignment: .trailing)
                    Text("Up").frame(width: Column.rate, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .groupTitle(theme)
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
        let running = status == .running
        return HStack(spacing: 16) {
            HStack(spacing: 8) {
                // A light only: whether it is carrying anything is the point.
                Circle().fill(running ? theme.online : theme.secondaryText.opacity(0.3))
                    .frame(width: 7, height: 7)
                Text(server.displayName)
                    .lineLimit(1)
            }
            .frame(width: Column.server, alignment: .leading)
            Text(totals(status, stats))
                .foregroundStyle(running ? theme.secondaryText : status.color(stopped: theme.secondaryText))
                .lineLimit(1)
                .frame(width: Column.total, alignment: .leading)
            Text(running ? stats.map { "\($0.connections)" } ?? "\u{2013}" : "\u{2013}")
                .frame(width: Column.connections, alignment: .trailing)
            Text(running ? "\u{2193} " + perSecond(rates.reduce(0) { $0 + $1.bytesInPerSecond }) : "\u{2013}")
                .foregroundStyle(running ? theme.online : theme.text)
                .frame(width: Column.rate, alignment: .trailing)
            Text(running ? "\u{2191} " + perSecond(rates.reduce(0) { $0 + $1.bytesOutPerSecond }) : "\u{2013}")
                .foregroundStyle(running ? theme.ansi(12) : theme.text)
                .frame(width: Column.rate, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .monospacedDigit()
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
            guard let stats else { return "Connected" }
            return "\(ByteCountFormatter.numeric(stats.bytesIn)) in \u{00B7} \(ByteCountFormatter.numeric(stats.bytesOut)) out"
        case .starting:            return "Connecting\u{2026}"
        case .retrying(let why):   return why
        case .failed(let why):     return why
        case .stopped:             return "Not running"
        }
    }

    private func perSecond(_ rate: Double) -> String { ByteCountFormatter.numeric(Int64(rate)) + "/s" }
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
    let page: SettingsPage

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.formStyle(WideFormStyle(page: page))
        } else {
            content.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

/// Settings' form: each section a floating plate under a small capitalised
/// title, open until the title is clicked. A section with no title is open
/// always, as is one marked bare, whose content is laid out by itself.
@available(macOS 15, *)
struct WideFormStyle: FormStyle {
    let page: SettingsPage

    func makeBody(configuration: Configuration) -> some View {
        Cards(page: page, content: configuration.content)
            .labeledContentStyle(RowLabeledContentStyle())
            .toggleStyle(RowToggleStyle())
    }

    private struct Cards: View {
        @Environment(Theme.self) private var theme
        let page: SettingsPage
        let content: Configuration.Content
        /// Which cards are folded, by page and place, for as long as the
        /// tab is. Open by default: the page shows what is set, as System
        /// Settings does, rather than a list of headings to click into.
        @State private var folded: Set<String> = []

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Group(sections: content) { sections in
                    ForEach(sections.indices, id: \.self) { index in
                        let section = sections[index]
                        if section.containerValues.isBare {
                            VStack(alignment: .leading, spacing: 10) {
                                if !section.header.isEmpty {
                                    section.header.groupTitle(theme)
                                        .padding(.horizontal, 6)
                                }
                                section.content
                            }
                        } else if !section.content.isEmpty {
                            card(section, key: "\(page.rawValue)/\(index)")
                        }
                    }
                    }
                }
                // The page title's margin.
                .padding(.horizontal, SettingsTab.margin)
                .padding(.bottom, 56)
            }
        }

        private func card(_ section: SectionConfiguration, key: String) -> some View {
            Group(subviews: section.content) { rows in
                let titled = !section.header.isEmpty
                let isOpen = !titled || !folded.contains(key)
                VStack(alignment: .leading, spacing: 10) {
                    // The title above the plate, as a grouped form heads its
                    // sections; a click on it folds the plate away.
                    if titled {
                        CardTitle(isOpen: isOpen) {
                            section.header
                        } toggle: {
                            withAnimation(.snappy(duration: 0.2)) {
                                if isOpen { folded.insert(key) } else { folded.remove(key) }
                            }
                        }
                    }
                    if isOpen {
                        VStack(spacing: 0) {
                            ForEach(rows.indices, id: \.self) { index in
                                if index > 0 { Divider().opacity(0.5).padding(.horizontal, 18) }
                                rows[index]
                                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 3)
                            }
                        }
                        .padding(.vertical, 2)
                        .plate()
                    }
                }
            }
        }
    }

    /// A section's name over its plate, small and spaced so the rows under
    /// it lead, and a chevron that shows while hovered or folded.
    private struct CardTitle<Title: View>: View {
        @Environment(Theme.self) private var theme
        let isOpen: Bool
        @ViewBuilder let title: Title
        let toggle: () -> Void

        @State private var isHovering = false

        var body: some View {
            HStack(spacing: 6) {
                title.groupTitle(theme)
                if isHovering || !isOpen {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
        }
    }
}

extension View {
    /// A card for a group of rows: a faint fill and an inner hairline, in
    /// the large corners of the system's glass.
    func plate(radius: CGFloat = 18) -> some View {
        modifier(Plate(radius: radius))
    }

    /// A section's title: small, semibold and grey, in its own case.
    func groupTitle(_ theme: Theme) -> some View {
        font(theme.ui(12.5, weight: .semibold))
            .foregroundStyle(theme.secondaryText.opacity(0.85))
    }
}

private struct Plate: ViewModifier {
    @Environment(Theme.self) private var theme
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // A pane of frosted light on the page: a faint fill and an inner
        // hairline, no shadow.
        content
            .background(shape.fill(theme.text.opacity(0.045)))
            .overlay(shape.strokeBorder(theme.text.opacity(0.06)))
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

