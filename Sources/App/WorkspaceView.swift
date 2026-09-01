import SwiftUI

/// The window.
///
/// Three panels side by side, as separate cards rather than flush panes: the
/// activity bar, whichever panel it selects, and the terminals. The gaps are
/// what make the panels read as independent things you can collapse and resize,
/// rather than one surface divided up.
struct WorkspaceView: View {
    @Environment(Theme.self) private var theme
    @Bindable var workspace: Workspace
    @Bindable var model: AppModel

    @State private var activity: Activity? = .servers
    @State private var search = ""
    @State private var panelWidth: CGFloat = 300
    @State private var isDraggingDivider = false

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
    }

    private var workspaceLayout: some View {
        VStack(spacing: 0) {
            if !workspace.isFocusMode { titleBar }
            cards
        }
        // No padding above the title bar: it has to start where the window's
        // own buttons already are, and those stay where macOS puts them.
        .padding(.horizontal, theme.windowButtonInset)
        .padding(.bottom, theme.windowButtonInset)
        .padding(.top, workspace.isFocusMode ? theme.windowButtonInset : 0)
    }

    /// The strip the window's own buttons sit in.
    ///
    /// Outside the cards, so it reads as belonging to the window rather than
    /// to any one panel -- and so the search stays put when the sidebar is
    /// collapsed. Its height is what puts the search on the buttons' own line;
    /// the buttons themselves are left exactly where macOS placed them.
    private var titleBar: some View {
        // The title is centred on the window, not on the space left over
        // between the buttons and the search -- so it stays put as the search
        // field grows and shrinks.
        ZStack {
            Text("Termther")
                .font(theme.ui(12, weight: .medium))
                .foregroundStyle(theme.secondaryText)

            HStack(spacing: 0) {
                // The space the close, minimise and zoom buttons occupy.
                Color.clear.frame(width: 64)
                Spacer(minLength: 8)
                SearchField(text: $search)
            }
        }
        // Centred in the strip rather than pinned to the buttons' line: the
        // strip reads as one band, and its contents sit in the middle of it.
        .frame(height: Self.topStrip)
    }

    private var cards: some View {
        HStack(spacing: 0) {
            if workspace.isFocusMode { EmptyView() } else { chrome }
            Card {
                terminalArea
            }
        }
    }

    /// The activity bar and whatever panel it has open.
    @ViewBuilder
    private var chrome: some View {
        Group {
            // The traffic lights live inside this card rather than above every
            // card: insetting the whole row left a band of dead space, and
            // insetting only this one left the tops out of line. It is drawn a
            // shade lighter so the buttons have something to be seen against.
            Card(background: theme.raisedBackground) {
                ActivityBar(selection: $activity.animation(.snappy(duration: 0.18))) {
                    workspace.openSettings()
                }
            }
            .frame(width: 44)

            Spacer().frame(width: 8)

            if let activity {
                Card {
                    SidePanel(activity: activity, model: model, search: search) { server in
                        workspace.open(server, using: model)
                    }
                }
                .frame(width: panelWidth)
                .transition(.move(edge: .leading).combined(with: .opacity))

                divider
            }
        }
    }

    /// The gap between the cards and the window's edges.
    static let outerPadding: CGFloat = 14

    /// The title strip. Its contents are 26pt tall and top-aligned, so they
    /// land on the same line as the window's buttons; the rest is the gap
    /// before the cards begin.
    static let topStrip: CGFloat = 42

    /// A thin drag target between the panel and the terminals.
    ///
    /// Deliberately wider than it looks: an invisible margin makes it easy to
    /// grab without a visible bar thick enough to be noticed.
    private var divider: some View {
        Color.clear
            .frame(width: 8)
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
        VStack(spacing: 0) {
            tabStrip
            content
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        TabButton(
                            title: tab.title,
                            isSelected: tab.id == workspace.selection,
                            select: { workspace.selection = tab.id },
                            close: { workspace.close(tabID: tab.id) })
                    }
                }
            }

            Button {
                workspace.newLocalTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help("New terminal (⌘T)")
        }
        .padding(.horizontal, 6)
        .frame(height: Self.topStrip)
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
                .font(theme.ui(11))
                .lineLimit(1)
            // The close button appears on hover, so a row of tabs stays quiet.
            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .frame(minWidth: 80, maxWidth: 170)
        .background(isSelected ? theme.selection : (isHovering ? theme.hover : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}
