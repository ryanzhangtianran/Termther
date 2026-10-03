import AppKit
import Core
import Foundation
import SwiftUI

/// The terminal side of the window; the tools live in `ToolsSidebar`.
struct WorkspaceView: View {
    @Environment(Theme.self) private var theme
    @Bindable var workspace: Workspace
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.state {
            case .opening, .locked:
                // Nothing behind the gate is meaningful yet, so it takes the
                // whole window rather than floating over a disabled workspace.
                VaultGate(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.windowBackground)
            case .unlocked:
                terminalArea
            }
        }
    }

    private var terminalArea: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.background.swiftUI)
    }

    /// Every terminal stays in the hierarchy, hidden rather than removed.
    ///
    /// A tab keeps running while it is not showing -- that is the whole point
    /// of a tab -- and rebuilding the view would drop its pty. Hiding also
    /// keeps the Metal layer alive, so switching back is instant instead of a
    /// blank frame while the first draw lands.
    private var content: some View {
        ZStack {
            // Terminals stay mounted whichever tab is showing; settings is a
            // plain view and can come and go.
            theme.palette.background.swiftUI
            GeometryReader { geometry in
                ForEach(workspace.tabs) { tab in
                    if let tree = tab.tree {
                        panes(of: tree, in: CGRect(origin: .zero, size: geometry.size))
                            .opacity(tab.id == workspace.selection ? 1 : 0)
                            .allowsHitTesting(tab.id == workspace.selection)
                    }
                }
            }
            // Breathing room, so a prompt does not start against the
            // window's edge -- and more above: the terminal runs up
            // under the titlebar, and the first row reads as part of
            // it otherwise.
            .padding(10)
            .padding(.top, 28)
            if workspace.selection == Workspace.Tab.settings.id {
                SettingsTab(model: model, workspace: workspace)
            }
            if workspace.tabs.isEmpty {
                Text("No tabs")
                    .font(theme.ui(13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A tab's panes, each placed where the tree puts it rather than nested
    /// in stacks: a terminal keeps its place in the hierarchy when a split
    /// is added around it, so nothing is torn down and remounted.
    private func panes(of tree: Workspace.SplitTree, in rect: CGRect) -> some View {
        let layout = PaneLayout(tree.root, in: rect)
        return ZStack {
            ForEach(tree.leaves) { session in
                if let frame = layout.panes[session.id] {
                    TerminalSurface(session: session)
                        .frame(width: frame.width, height: frame.height)
                        // The panes without the keyboard sit back a little,
                        // as Ghostty's do: a mark that is no mark at all.
                        .opacity(tree.leaves.count > 1 && session !== tree.focused ? 0.65 : 1)
                        .animation(.easeOut(duration: 0.15), value: tree.focused === session)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            ForEach(layout.dividers) { divider in
                PaneDivider(divider: divider, tree: tree)
            }
        }
    }

}

/// Where each pane and divider of a tree goes within a rect.
private struct PaneLayout {
    struct Divider: Identifiable {
        /// The split's place in the tree, which outlives any resize.
        let id: String
        let frame: CGRect
        let axis: Axis
        let fraction: CGFloat
        /// The room the split divides, so a drag reads as a fraction of it.
        let length: CGFloat
        /// The whole tree with this divider moved.
        let moved: (CGFloat) -> Workspace.Pane
    }

    /// Between two panes; the divider is drawn down the middle of it.
    static let gap: CGFloat = 14

    private(set) var panes: [UUID: CGRect] = [:]
    private(set) var dividers: [Divider] = []

    init(_ root: Workspace.Pane, in rect: CGRect) {
        place(root, in: rect, path: "", put: { $0 })
    }

    /// `put` builds the whole tree around a replacement for `pane`.
    private mutating func place(_ pane: Workspace.Pane, in rect: CGRect, path: String,
                                put: @escaping (Workspace.Pane) -> Workspace.Pane) {
        switch pane {
        case .leaf(let session):
            panes[session.id] = rect
        case .split(let axis, let first, let second, let fraction):
            let room = max(0, (axis == .horizontal ? rect.width : rect.height) - Self.gap)
            let head = room * fraction
            let (a, divider, b) = axis == .horizontal
                ? (CGRect(x: rect.minX, y: rect.minY, width: head, height: rect.height),
                   CGRect(x: rect.minX + head, y: rect.minY, width: Self.gap, height: rect.height),
                   CGRect(x: rect.minX + head + Self.gap, y: rect.minY, width: room - head, height: rect.height))
                : (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: head),
                   CGRect(x: rect.minX, y: rect.minY + head, width: rect.width, height: Self.gap),
                   CGRect(x: rect.minX, y: rect.minY + head + Self.gap, width: rect.width, height: room - head))
            dividers.append(Divider(id: path, frame: divider, axis: axis, fraction: fraction, length: room) {
                put(.split(axis: axis, first: first, second: second, fraction: $0))
            })
            place(first, in: a, path: path + "1") {
                put(.split(axis: axis, first: $0, second: second, fraction: fraction))
            }
            place(second, in: b, path: path + "2") {
                put(.split(axis: axis, first: first, second: $0, fraction: fraction))
            }
        }
    }
}

/// The line between two panes, dragged to give one more of the room.
private struct PaneDivider: View {
    @Environment(Theme.self) private var theme
    let divider: PaneLayout.Divider
    let tree: Workspace.SplitTree

    /// Where the divider was when the drag began; the drag is measured
    /// from there, not from wherever the last tick left it.
    @State private var startFraction: CGFloat?

    var body: some View {
        let across = divider.axis == .horizontal
        Rectangle()
            .fill(theme.text.opacity(0.12))
            .frame(width: across ? 1 : nil, height: across ? nil : 1)
            .frame(width: divider.frame.width, height: divider.frame.height)
            .contentShape(Rectangle())
            .position(x: divider.frame.midX, y: divider.frame.midY)
            .onHover { hovering in
                if hovering { (across ? NSCursor.resizeLeftRight : .resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = startFraction ?? divider.fraction
                    startFraction = start
                    let moved = across ? value.translation.width : value.translation.height
                    tree.root = divider.moved(Workspace.Pane.clamped(start + moved / divider.length))
                }
                .onEnded { _ in startFraction = nil })
    }
}

/// The tools column. It sits in an AppKit sidebar split item, which is what
/// gives it the system's own sidebar glass and puts the window's buttons on it;
/// so it draws no background of its own.
struct ToolsSidebar: View {
    @Environment(Theme.self) private var theme
    @Bindable var workspace: Workspace
    @Bindable var model: AppModel

    @State private var showsConnections = true
    @State private var showsSessions = true
    @State private var addServer = false

    var body: some View {
        VStack(spacing: 0) {
            // While Settings is open the column is its table of contents, the
            // way System Settings keeps its panes in a sidebar.
            if workspace.selection == Workspace.Tab.settings.id {
                settingsNavigation
            } else {
                workspaceNavigation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $addServer) {
            ServerEditor(model: model, server: Server(name: "", host: "", username: ""))
        }
    }

    /// A terminal's proxy switch: its own shell through the proxy -- this
    /// Mac's for a local one, the server's tunnel back here for an SSH one.
    private func proxySwitch(for tab: Workspace.Tab) -> SidebarRow.Switch? {
        guard let session = tab.session, !session.isDisconnected else { return nil }
        if session.isLocal {
            return .init(isOn: session.usesProxy) { model.localProxy.toggle(session) }
        }
        guard let id = session.serverID else { return nil }
        return .init(isOn: session.usesProxy) { Task { await model.toggleProxy(for: session, serverID: id) } }
    }

    /// An SSH tab's bandwidth, while there is some to speak of: an idle
    /// session only trickles keepalives, and a row of zeros is noise.
    private func bandwidth(of tab: Workspace.Tab) -> String? {
        if tab.session?.isDisconnected == true { return "disconnected" }
        guard let rate = tab.session?.rate,
              rate.bytesInPerSecond + rate.bytesOutPerSecond >= 1024 else { return nil }
        return "\u{2193}\(Self.compact(rate.bytesInPerSecond)) "
            + "\u{2191}\(Self.compact(rate.bytesOutPerSecond))"
    }

    /// Bytes per second in three or four characters: 812B, 4.2K, 31M.
    static func compact(_ perSecond: Double) -> String {
        var value = perSecond
        var unit = 0
        let units = ["B", "K", "M", "G"]
        while value >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return (unit > 0 && value < 10 ? String(format: "%.1f", value) : String(Int(value)))
            + units[unit]
    }

    /// Runs a coding agent in a tab's shell, where it is, through the proxy:
    /// the shell is put through it first when it is not already, and the
    /// command typed after, at the same prompt. Refused with a beep while a
    /// program has the terminal.
    private func agentButtons(for session: TerminalSession) -> [SidebarRow.Accessory] {
        AgentTool.allCases.map { tool in
            .init(id: tool.rawValue, image: tool.logo, help: "Run \(tool.title) here, through the proxy") {
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
    }

    /// The + beside a group title.
    private func addButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.secondaryText)
        .help(help)
    }

    private var settingsNavigation: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                // Closing the Settings tab lands on the terminal beside it.
                SidebarRow(icon: "chevron.left", title: "Back") {
                    workspace.close(tabID: Workspace.Tab.settings.id)
                }
                SectionHeader(title: "Settings")
                ForEach(SettingsPage.allCases) { page in
                    SidebarRow(icon: page.icon, logo: page.logo, title: page.title,
                               isSelected: workspace.settingsPage == page) {
                        workspace.settingsPage = page
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var workspaceNavigation: some View {
        // One scroll for the whole column: open sections take the room
        // their content needs, and the column scrolls past it, rather
        // than each squeezing a list of its own into a fixed box.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                // The group titles are the folds: the servers sit straight
                // under theirs, with no row of their own in between.
                SectionHeader(title: "Connections", isExpanded: $showsConnections) {
                    addButton("Add Server") { addServer = true }
                }
                if showsConnections {
                    ServerList(model: model, add: { addServer = true }) {
                        workspace.open($0, using: model)
                    }
                    .transition(.opacity)
                }

                SectionHeader(title: "Sessions", isExpanded: $showsSessions) {
                    addButton("New Tab") { workspace.newLocalTab() }
                }
                if showsSessions {
                    // Settings is a tab too, but it is shown by the Settings
                    // row below rather than listed as a session.
                    ForEach(workspace.tabs.filter { $0.id != Workspace.Tab.settings.id }) { tab in
                        SidebarRow(icon: "terminal",
                                   title: tab.title,
                                   detail: bandwidth(of: tab),
                                   proxy: proxySwitch(for: tab),
                                   isSelected: tab.id == workspace.selection,
                                   wantsAttention: tab.tree?.leaves.contains { $0.needsAttention } == true,
                                   accessories: (tab.session.map(agentButtons) ?? [])
                                       + [.init(icon: "xmark", help: "Close") {
                                           workspace.close(tabID: tab.id)
                                       }]) {
                            workspace.selection = tab.id
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }

        HStack(spacing: 4) {
            SidebarRow(icon: "gearshape", title: "Settings") {
                workspace.openSettings()
            }
            // Down here as a light, not up with the connections: it is worth a
            // glance, and switched in Settings or the View menu.
            if model.vpn.profile != nil {
                VPNLight(vpn: model.vpn) {
                    workspace.settingsPage = .vpn
                    workspace.openSettings()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

/// The VPN at a glance: a light beside the word. What it means in full is on
/// hover; a click opens its page in Settings.
private struct VPNLight: View {
    @Environment(Theme.self) private var theme
    let vpn: VPNController
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(light)
                .frame(width: 7, height: 7)
            Text("VPN")
                .font(theme.ui(12, weight: SidebarRowStyle.titleWeight))
                .tracking(SidebarRowStyle.titleTracking)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, SidebarRowStyle.inset)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovering ? theme.hover : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering in
            // Eased, so buttons that appear on hover slide in rather than pop.
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
        .help(detail)
    }

    private var light: Color {
        switch vpn.state {
        case .on:         .green
        case .connecting: .yellow
        case .failed:     .orange
        case .off:        theme.secondaryText.opacity(0.5)
        }
    }

    private var detail: String {
        switch vpn.state {
        case .on(let address):    "VPN connected as \(address)"
        case .connecting:         "VPN connecting\u{2026}"
        case .failed(let reason): reason
        case .off:                "VPN off"
        }
    }
}

/// A group title in the sidebar, in the system's small grey style.
/// Given `isExpanded`, the title is also the fold: a click shows or hides the
/// group, and a chevron says so while hovered or folded.
private struct SectionHeader<Trailing: View>: View {
    @Environment(Theme.self) private var theme
    let title: String
    var isExpanded: Binding<Bool>?
    @ViewBuilder var trailing: Trailing

    @State private var isHovering = false

    init(title: String, isExpanded: Binding<Bool>? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.isExpanded = isExpanded
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(theme.ui(14))
                .foregroundStyle(theme.secondaryText)
            if let isExpanded, isHovering || !isExpanded.wrappedValue {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            Spacer()
            trailing
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let isExpanded else { return }
            withAnimation(.snappy(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
        }
        .onHover { hovering in
            // Eased, so buttons that appear on hover slide in rather than pop.
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Every row in the sidebar: an icon, a title, and optionally one action that
/// appears on hover.
private struct SidebarRow: View {
    /// A switch at the end of the row, lit while on.
    struct Switch {
        let isOn: Bool
        let toggle: () -> Void
    }

    /// A button at the end of the row, shown on hover.
    struct Accessory: Identifiable {
        let id: String
        let image: Image
        let help: String
        let action: () -> Void

        init(id: String, image: Image, help: String, action: @escaping () -> Void) {
            self.id = id
            self.image = image
            self.help = help
            self.action = action
        }

        init(icon: String, help: String, action: @escaping () -> Void) {
            self.init(id: icon, image: Image(systemName: icon), help: help, action: action)
        }
    }

    @Environment(Theme.self) private var theme
    let icon: String
    /// Drawn instead of `icon` when given: an agent's own mark.
    var logo: Image?
    let title: String
    /// A short reading at the end of the row, such as a tab's bandwidth.
    var detail: String?
    var proxy: Switch?
    var isSelected = false
    /// A light before the title, while the tab has something to look at.
    var wantsAttention = false
    var accessories: [Accessory] = []
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SidebarRowStyle.iconGap) {
            // The same colour as the title, so icon and name read as one.
            (logo ?? Image(systemName: icon))
                .symbolRenderingMode(.monochrome)
                .sidebarIcon()
                .foregroundStyle(theme.text)
            if wantsAttention {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 7, height: 7)
                    .transition(.opacity)
            }
            Text(title)
                .font(theme.ui(12, weight: SidebarRowStyle.titleWeight))
                .tracking(SidebarRowStyle.titleTracking)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let detail, !(isHovering && !accessories.isEmpty) {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            // Shown while on, and on hover to turn on, as on a server's row.
            if let proxy, proxy.isOn || isHovering {
                Button(action: proxy.toggle) {
                    Image(systemName: "globe")
                        .font(.system(size: SidebarRowStyle.trailingIconSize,
                                      weight: SidebarRowStyle.iconWeight))
                        .foregroundStyle(proxy.isOn ? theme.accent : theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(proxy.isOn ? "Proxied \u{2014} click to stop" : "Proxy This Terminal")
                .transition(.revealFromTrailing)
            }
            if isHovering {
                ForEach(accessories) { accessory in
                    Button(action: accessory.action) { accessoryIcon(accessory.image) }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                        .help(accessory.help)
                        .transition(.revealFromTrailing)
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: wantsAttention)
        .sidebarRow(hovering: isHovering, selected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering in
            // Eased, so buttons that appear on hover slide in rather than pop.
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
    }

    private func accessoryIcon(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .fontWeight(SidebarRowStyle.iconWeight)
            .frame(width: SidebarRowStyle.trailingIconSize, height: SidebarRowStyle.trailingIconSize)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}
