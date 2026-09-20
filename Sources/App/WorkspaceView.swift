import Core
import Foundation
import SwiftUI

/// The window, split into a tools sidebar and a terminal workspace.
struct WorkspaceView: View {
    @Environment(Theme.self) private var theme
    @Bindable var workspace: Workspace
    @Bindable var model: AppModel

    @State private var activity: Activity?
    @State private var panelWidth: CGFloat = 300
    @State private var isDraggingDivider = false
    @State private var addServer = false
    @State private var addProxy = false
    @State private var addVPN = false

    private let minimumPanelWidth: CGFloat = 220
    private let maximumPanelWidth: CGFloat = 420

    var body: some View {
        Group {
            switch model.state {
            case .needsSetup, .locked:
                // Nothing behind the gate is meaningful yet, so it takes the
                // whole window rather than floating over a disabled workspace.
                VaultGate(model: model)
            case .unlocked:
                workspaceLayout
            }
        }
        .background(theme.windowBackground)
        .sheet(isPresented: $addServer) {
            ServerEditor(model: model, server: Server(name: "", host: "", username: ""))
        }
        .sheet(isPresented: $addProxy) {
            if let server = model.servers.first, let id = server.id {
                ProxyEditor(model: model, preset: PortForwardPreset(
                    serverId: id, direction: .remote,
                    bindPort: ProxyEnvironment.defaultRemotePort,
                    targetHost: "127.0.0.1", targetPort: model.forwards.proxyLocalPort,
                    autoStart: false, keepAlive: true, exportsEnvironment: true))
            } else {
                Text("Add a server first").padding()
            }
        }
        .sheet(isPresented: $addVPN) {
            VPNEditor(model: model, profile: VPNProfile(
                name: "", gateway: "", username: "",
                sealed: .init(ciphertext: Data(), nonce: Data())))
        }
    }

    private var workspaceLayout: some View {
        HStack(spacing: 0) {
            if !workspace.isFocusMode {
                toolsSidebar
                divider
            }
            terminalArea
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var toolsSidebar: some View {
        VStack(spacing: 0) {
            TitlebarMaterial()
                .frame(height: 28)

            VStack(spacing: 3) {
                ForEach(Activity.allCases) { item in
                    VStack(spacing: 0) {
                        ToolButton(item: item, selected: activity == item,
                                   trailing: AnyView(actionMenu(for: item))) {
                            withAnimation(.snappy(duration: 0.18)) {
                                activity = activity == item ? nil : item
                            }
                        }

                        if activity == item {
                            SidePanel(activity: item, model: model, search: "", open: { server in
                                workspace.open(server, using: model)
                            })
                            .frame(maxHeight: 220)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Spacer(minLength: 0)

            sessionList

            Spacer(minLength: 0)

            ToolButton(title: "Settings", icon: "gearshape", selected: false) {
                workspace.openSettings()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(width: panelWidth)
        .background(theme.raisedBackground)
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SESSION")
                    .font(theme.ui(12, weight: .semibold))
                    .foregroundStyle(theme.text.opacity(0.82))
                Spacer()
                Button {
                    workspace.newLocalTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text.opacity(0.9))
                .help("New terminal (⌘T)")
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        TabButton(
                            title: tab.title,
                            isSelected: tab.id == workspace.selection,
                            select: { workspace.selection = tab.id },
                            close: { workspace.close(tabID: tab.id) })
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 180)
        .layoutPriority(1)
        .foregroundStyle(theme.text.opacity(0.9))
    }

    @ViewBuilder
    private func actionMenu(for item: Activity) -> some View {
        SwiftUI.Menu {
            switch item {
            case .servers:
                Button("Add Server", systemImage: "plus") { addServer = true }
            case .proxy:
                Button("Edit Proxy", systemImage: "pencil") { addProxy = true }
            case .vpn:
                Button("Add VPN", systemImage: "plus") { addVPN = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(theme.text.opacity(0.92))
        .help("Actions")
    }

    /// A thin drag target between the tools and the terminal.
    private var divider: some View {
        theme.border
            .frame(width: 1)
            .contentShape(Rectangle())
            .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        isDraggingDivider = true
                        panelWidth = min(maximumPanelWidth,
                                         max(minimumPanelWidth, value.location.x - 52))
                    }
                    .onEnded { _ in isDraggingDivider = false })
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
            ForEach(workspace.sessions) { session in
                TerminalSurface(session: session)
                    // Breathing room, so a prompt does not start against the
                    // card's edge. Tighter at the top, where the tab strip
                    // above already provides separation.
                    .padding(.top, 0)
                    .padding([.leading, .trailing, .bottom], 10)
                    .opacity(session.id.uuidString == workspace.selection ? 1 : 0)
                    .allowsHitTesting(session.id.uuidString == workspace.selection)
            }
            if workspace.selection == Workspace.Tab.settings.id {
                SettingsTab(model: model)
            }
            if workspace.tabs.isEmpty {
                Text("⌘T for a local shell, or double-click a server.")
                    .font(theme.ui(12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var showsTerminal: Bool {
        workspace.selection != Workspace.Tab.settings.id && !workspace.tabs.isEmpty
    }
}

private struct TitlebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .titlebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .titlebar
        nsView.blendingMode = .withinWindow
        nsView.state = .active
    }
}

/// One panel of the layout.
private struct Card<Content: View>: View {
    @Environment(Theme.self) private var theme
    var padding: CGFloat = 0
    var background: SwiftUI.Color?
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background ?? theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.border, lineWidth: 0.5)
            }
    }
}

private struct TabButton: View {
    @Environment(Theme.self) private var theme
    let title: String
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(theme.ui(13))
                .lineLimit(1)
            Spacer(minLength: 0)
            // The close button appears on hover, so a row of tabs stays quiet.
            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? theme.selection : (isHovering ? theme.hover : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}

private struct ToolButton: View {
    @Environment(Theme.self) private var theme
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    let trailing: AnyView?

    init(item: Activity, selected: Bool, trailing: AnyView? = nil, action: @escaping () -> Void) {
        title = item.title
        icon = item.icon
        self.selected = selected
        self.trailing = trailing
        self.action = action
    }

    init(title: String, icon: String, selected: Bool, trailing: AnyView? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.selected = selected
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20, height: 20)
                    Text(title)
                        .font(theme.ui(13, weight: selected ? .medium : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if let trailing {
                trailing
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 32)
        .foregroundStyle(selected ? theme.text : theme.text.opacity(0.92))
        .background(selected ? theme.selection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help(title)
    }
}
