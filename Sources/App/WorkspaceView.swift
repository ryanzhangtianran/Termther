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
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            // Up into the titlebar's lower edge: the first row starts level
            // with the window's buttons rather than a gap below them. The
            // titlebar takes the clicks over the top few points of it.
            .padding(.top, workspace.isFocusMode ? 12 : 32)
            if workspace.selection == Workspace.Tab.settings.id {
                SettingsTab(model: model, workspace: workspace)
                    // A faint wash of the scheme's blue from the top: the
                    // page reads as lit glass rather than a flat fill.
                    .background {
                        RadialGradient(colors: [theme.ansi(4).opacity(0.10), .clear],
                                       center: UnitPoint(x: 0.7, y: -0.1), startRadius: 0, endRadius: 700)
                            // The terminal's own ground, as the sidebar's
                            // column is: a darker one met it in a seam.
                            .background(theme.palette.background.swiftUI)
                            .ignoresSafeArea()
                    }
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

/// The servers and Settings, on an island of frosted glass inset from the
/// window's edges, the window's buttons on it. It sits in an AppKit sidebar
/// split item -- which, for all macOS 26 says, does not float on its own --
/// and paints the item in the terminal's background, so the island floats
/// on the same surface as the terminal. What is open is the tab strip's.
struct ToolsSidebar: View {
    @Environment(Theme.self) private var theme
    @Bindable var workspace: Workspace
    @Bindable var model: AppModel

    @State private var showsConnections = true
    @State private var addServer = false

    /// The gap round the island, and its corner: the window's own corner
    /// less the gap, so the two curves run parallel.
    static let inset: CGFloat = 10
    static let cornerRadius: CGFloat = 16

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
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.inset)
        .background {
            GlassPanel(cornerRadius: Self.cornerRadius)
                .padding(Self.inset)
                .ignoresSafeArea()
        }
        .background(theme.palette.background.swiftUI.ignoresSafeArea())
        .sheet(isPresented: $addServer) {
            ServerEditor(model: model, server: Server(name: "", host: "", username: ""))
        }
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

    private var settingsNavigation: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                // Closing the Settings tab lands on the terminal beside it.
                // Clear of the window's buttons by the same gap the servers'
                // heading keeps on the other side.
                SidebarRow(icon: "chevron.left", title: "Back") {
                    workspace.close(tabID: Workspace.Tab.settings.id)
                }
                .padding(.top, 12)
                SectionHeader(title: "Settings")
                ForEach(SettingsPage.allCases) { page in
                    SidebarRow(icon: page.icon, logo: page.logo, title: page.title,
                               isSelected: workspace.settingsPage == page) {
                        workspace.settingsPage = page
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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
                SectionHeader(title: "Servers", isExpanded: $showsConnections) {
                    TileButton(symbol: "plus", size: 20, help: "Add Server") { addServer = true }
                }
                if showsConnections {
                    ServerList(model: model, workspace: workspace, add: { addServer = true }) {
                        workspace.open($0, using: model)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }

        HStack(spacing: 4) {
            SidebarRow(icon: "gearshape", title: "Settings") {
                workspace.openSettings()
            }
            // Down here as a chip, not up with the connections: it is worth a
            // glance, and switched in Settings or the View menu.
            if model.vpn.profile != nil {
                VPNButton(vpn: model.vpn) {
                    workspace.settingsPage = .vpn
                    workspace.openSettings()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// The VPN at a glance: a chip in the colour of its state. What it means
/// in full is on hover; a click opens its page in Settings.
private struct VPNButton: View {
    @Environment(Theme.self) private var theme
    let vpn: VPNController
    let open: () -> Void

    var body: some View {
        // An icon like the rest of the column, lit in the state's colour.
        TileButton(symbol: "lock.shield", color: color, size: 22, help: detail, action: open)
            .padding(.trailing, SidebarRowStyle.inset)
    }

    private var color: Color? {
        switch vpn.state {
        case .on:         theme.online
        case .connecting: theme.waiting
        case .failed:     theme.failing
        case .off:        nil
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

/// A group title in the sidebar: small, heavy, spaced capitals, so it marks
/// the group without competing with the names under it.
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
                .font(theme.ui(12.5, weight: .semibold))
                .foregroundStyle(theme.text.opacity(0.5))
            if let isExpanded, isHovering || !isExpanded.wrappedValue {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            Spacer()
            trailing
        }
        .padding(.leading, SidebarRowStyle.inset)
        .padding(.trailing, 4)
        .padding(.top, 16)
        .padding(.bottom, 6)
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

/// A row of the sidebar's own: Back, a Settings page, Settings itself.
private struct SidebarRow: View {
    @Environment(Theme.self) private var theme
    let icon: String
    /// Drawn instead of `icon` when given: an agent's own mark.
    var logo: Image?
    let title: String
    var isSelected = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SidebarRowStyle.iconGap) {
            Tile(symbol: icon, image: logo, size: SidebarRowStyle.iconColumn)
            Text(title)
                .font(theme.ui(SidebarRowStyle.titleSize, weight: SidebarRowStyle.titleWeight))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .sidebarRow(hovering: isHovering, selected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
    }
}
