import AppKit
import Core
import Net
import SSH
import SwiftUI
import VT

@MainActor
public final class TermtherApp: NSObject, NSApplicationDelegate, WorkspaceCommands {
    private let theme = Theme()
    // Nothing is opened until the saved appearance is back: a terminal built
    // before then measures its grid with the default font and keeps it, which
    // is why the first tab used to come up the wrong size while ⌘T was fine.
    private let workspace = Workspace()
    private let model = AppModel()
    private var window: NSWindow!
    private var sidebar: NSSplitViewItem!
    private var isTerminating = false
    private var hasAnsweredTerminate = false

    /// A session to open instead of a local shell, when launched with `ssh`.
    public var initialRemote: (title: String, io: any SessionIO)?

    /// The narrowest the pane beside the sidebar may be; see where it is set.
    static let sidebarWidth: CGFloat = 280
    static let detailMinimumWidth: CGFloat = 950

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Menu.install(appName: "Termther")

        // Said once at startup, because a missing switch and an unbuilt
        // feature look identical from the settings page.
        let methods = QuickUnlock.methodsDescription()
        FileHandle.standardError.write(Data(
            ("termther: unlock-with-mac: \(methods ?? "unavailable")"
             + (QuickUnlock.lastAvailabilityError.map { " (\($0))" } ?? "")
             + ", enrolled=\(QuickUnlock.isEnrolled())\n").utf8))

        HostKeyCheck.install { [store = model.store] host, port, fingerprint in
            try await store.checkHostKey(host: host, port: port, fingerprint: fingerprint)
        }

        model.theme = theme
        model.onAppearanceChanged = { [weak self] in
            guard let self else { return }
            workspace.adopt(theme)
            // Set on the window, not the application: NSApp.appearance would
            // drag every panel and menu along with the terminal's colours.
            window.appearance = theme.appearance
            window.backgroundColor = theme.palette.background.swiftUI.nsColor
        }
        Task {
            await model.openAtLaunch()
            model.sessions.watchForStaleConnections()
            model.shellEnvironment.installZshIntegration()
            await model.restoreAppearance()
            await Shortcuts.restore(from: model.store)
            if let remote = initialRemote {
                workspace.open(title: remote.title, io: remote.io)
            } else {
                workspace.newLocalTab()
            }
            focusCurrentTerminal()
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Termther"
        window.titleVisibility = .hidden
        window.isOpaque = true
        // The terminal's own background, so the gap round the system's
        // floating sidebar is the same surface as the terminal.
        window.backgroundColor = theme.palette.background.swiftUI.nsColor
        window.appearance = theme.appearance
        // Nothing drawn across the top: just the sidebar and the terminal,
        // each running up to the window's edge.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty compact toolbar, for a titlebar of 40 rather than 32: room
        // to move the window's buttons inside the sidebar's island without
        // their being clipped, and no taller than that, since the titlebar
        // takes the clicks over the terminal's first lines.
        window.toolbar = NSToolbar(identifier: "main")
        window.toolbarStyle = .unifiedCompact

        // A real sidebar split item, not a lookalike: it is where the system
        // draws its own sidebar material -- Liquid Glass on macOS 26 -- and
        // the only thing the traffic lights know to sit on.
        let split = NSSplitViewController()
        sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(
            rootView: ToolsSidebar(workspace: workspace, model: model)
                .environment(theme)
                .themed(theme)))
        sidebar.allowsFullHeightLayout = true
        // Room for a session's path beside its hover buttons, and in
        // proportion to the window: a fifth of it or so.
        sidebar.minimumThickness = Self.sidebarWidth
        sidebar.maximumThickness = 420
        sidebar.canCollapse = true
        split.addSplitViewItem(sidebar)
        let terminal = NSHostingController(
            rootView: WorkspaceView(workspace: workspace, model: model)
                .environment(theme)
                .themed(theme))
        // The terminal runs up under the titlebar rather than starting below
        // it; the window's buttons are over the sidebar, not over the text.
        terminal.safeAreaRegions = []
        let detail = NSSplitViewItem(viewController: terminal)
        detail.titlebarSeparatorStyle = .none
        // Wide enough that nothing in Settings wraps: the Connections
        // monitor's columns are the widest thing there, at about 950.
        detail.minimumThickness = Self.detailMinimumWidth
        split.addSplitViewItem(detail)
        window.contentViewController = split
        // Assigning the controller sizes the window to the controller's view.
        window.setContentSize(NSSize(width: 1240, height: 780))
        // The detail alone, for when the sidebar is collapsed; with it open,
        // the split view's own minimums add up to more.
        window.contentMinSize = NSSize(width: Self.detailMinimumWidth, height: 600)
        split.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        updateSidebar()
        window.center()

        window.makeKeyAndOrderFront(nil)
        // AppKit lays the titlebar out again whenever it likes and puts the
        // buttons back where it keeps them; each button's own move is the
        // one moment that catches every time.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeWindowButtons() }
            }
        }
        // And after every event: the zoom button in particular is put back
        // without saying so. Three comparisons, so it costs nothing.
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeWindowButtons() }
        }
        placeWindowButtons()

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Where AppKit put each window button, kept the first time: the shift
    /// is applied to these, so laying the buttons out again cannot add up.
    private var buttonOrigins: [NSWindow.ButtonType: NSPoint] = [:]

    /// How far the window's buttons move in from where AppKit puts them --
    /// 12 and 13 in from the corner under a compact toolbar -- so they sit
    /// 12 inside the sidebar's island, which is 10 in from the window's edge.
    static let buttonShift = CGSize(width: 10, height: 9)

    /// Moves the window's buttons in from the corner. Setting a frame that
    /// is already right is skipped, so the frame-change observer that calls
    /// this does not call it again.
    private func placeWindowButtons() {
        let shift = Self.buttonShift
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            // AppKit's own place: remembered once, or taken again if it has
            // moved the button somewhere other than where it was left.
            let shifted = buttonOrigins[type].map { NSPoint(x: $0.x + shift.width, y: $0.y - shift.height) }
            if button.frame.origin == shifted { continue }
            buttonOrigins[type] = button.frame.origin
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x + shift.width,
                                          y: button.frame.origin.y - shift.height))
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting waits for the tunnels to be taken down properly.
    ///
    /// A reverse forward's listening socket belongs to the server, and sshd
    /// only frees the port when it is told to -- or when it notices the
    /// connection is gone, which can take a while. Exiting without cancelling
    /// leaves the port held, and the next run is refused it. So the quit is
    /// deferred until the cancels have gone out, and no longer: a server that
    /// has stopped answering must not be able to hold the app open.
    public func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        // Two independent tasks, and whichever arrives first answers.
        //
        // Not a task group: `withTaskGroup` waits for every child before it
        // returns, and cancelling a child only sets a flag. A task blocked
        // inside a synchronous C call ignores that flag and never finishes, so
        // the group never returned, the reply was never sent, and the app
        // could not be quit at all -- a worse failure than the one the budget
        // was there to prevent.
        Task { await teardown(); answerTerminate() }
        Task { try? await Task.sleep(for: .seconds(2)); answerTerminate() }
        return .terminateLater
    }

    private func answerTerminate() {
        guard !hasAnsweredTerminate else { return }
        hasAnsweredTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func teardown() async {
        // Forwards first: they are the ones holding something on the far side.
        await model.forwards.stopAll()
        await model.vpn.disconnect()
        await workspace.closeAll()
    }

    // MARK: - commands

    public func newTab(_ sender: Any?) {
        workspace.newLocalTab()
        focusCurrentTerminal()
    }

    public func closeTab(_ sender: Any?) {
        workspace.closeCurrent()
        focusCurrentTerminal()
    }

    public func selectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        workspace.selectTab(at: item.tag)
        focusCurrentTerminal()
    }

    public func nextTab(_ sender: Any?) {
        workspace.selectNext(by: 1)
        focusCurrentTerminal()
    }

    public func previousTab(_ sender: Any?) {
        workspace.selectNext(by: -1)
        focusCurrentTerminal()
    }

    public func toggleFocusMode(_ sender: Any?) {
        withAnimation(.snappy(duration: 0.2)) {
            workspace.isFocusMode.toggle()
        }
        // The window's own buttons go too. Leaving them would mean either the
        // terminal starts below them -- which is the chrome this mode exists to
        // remove -- or they sit on top of it. ⌘W and the menu still work, and
        // they come back once the sidebar has (see `updateSidebar`).
        if workspace.isFocusMode { setWindowButtons(hidden: true) }
        focusCurrentTerminal()
    }

    public func splitRight(_ sender: Any?) {
        workspace.split(.horizontal, using: model)
        focusCurrentTerminal()
    }

    public func splitDown(_ sender: Any?) {
        workspace.split(.vertical, using: model)
        focusCurrentTerminal()
    }

    public func focusNextPane(_ sender: Any?) {
        workspace.focusPane(by: 1)
        focusCurrentTerminal()
    }

    public func focusPreviousPane(_ sender: Any?) {
        workspace.focusPane(by: -1)
        focusCurrentTerminal()
    }

    public func equalizePanes(_ sender: Any?) {
        workspace.equalizePanes()
    }

    /// Sends the local terminal in front through the proxy, or stops -- the
    /// same as the switch on its row.
    public func toggleLocalProxy(_ sender: Any?) {
        guard let session = workspace.current, session.isLocal else { return }
        model.localProxy.toggle(session)
        focusCurrentTerminal()
    }

    /// Connects the VPN, or drops it. With no gateway yet there is nothing to
    /// connect, so it opens Settings where one is set up.
    public func toggleVPN(_ sender: Any?) {
        guard let profile = model.vpn.profile else {
            workspace.openSettings()
            return
        }
        Task {
            if model.vpn.state.isOn { await model.vpn.disconnect() }
            else { await model.vpn.connect(profile) }
        }
    }

    /// Opens the find bar over the terminal in front.
    public func find(_ sender: Any?) {
        workspace.current?.view.beginSearch()
    }

    public func checkForUpdates(_ sender: Any?) {
        Task { await Updater.checkForUpdates() }
    }

    /// The sidebar shows only once the vault is open, and not in focus mode.
    ///
    /// Re-arms itself: observation tracking fires once per registration.
    private func updateSidebar() {
        let collapsed = withObservationTracking {
            model.state != .unlocked || workspace.isFocusMode
        } onChange: {
            Task { @MainActor [weak self] in self?.updateSidebar() }
        }
        // Not compared against isCollapsed first: mid-animation it still
        // reports the old value, so an unlock that landed during the launch
        // collapse was skipped and the sidebar stayed shut. The launch state
        // is set before the window shows, where there is nothing to animate.
        guard window.isVisible else { sidebar.isCollapsed = collapsed; return }
        NSAnimationContext.runAnimationGroup { _ in
            sidebar.animator().isCollapsed = collapsed
        } completionHandler: { [weak self] in
            // Only now: AppKit lays the titlebar out on every frame of the
            // sidebar's move and puts the buttons back each time, and moving
            // them in again each frame made them twitch.
            guard let self, !workspace.isFocusMode else { return }
            setWindowButtons(hidden: false)
            placeWindowButtons()
        }
    }

    private func setWindowButtons(hidden: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
    }

    /// Keyboard focus has to follow the selected tab explicitly: SwiftUI keeps
    /// the hidden terminals in the hierarchy, so first responder does not move
    /// on its own.
    private func focusCurrentTerminal() {
        // After the hierarchy settles, or the view is not yet in the window.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.workspace.current?.view else { return }
            self.window.makeFirstResponder(view)
        }
    }
}

/// Ticks the switches in the View menu from their real state, asked each time
/// the menu opens: the VPN comes up and drops on its own, and either switch
/// can also be flipped in Settings.
extension TermtherApp: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleVPN(_:)):
            item.state = model.vpn.state.isOn ? .on : .off
            return model.vpn.state != .connecting
        case #selector(toggleLocalProxy(_:)):
            let session = workspace.current
            item.state = session?.usesProxy == true ? .on : .off
            return session?.isLocal == true
        case #selector(splitRight(_:)), #selector(splitDown(_:)):
            return workspace.current != nil
        case #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)), #selector(equalizePanes(_:)):
            return (workspace.currentTree?.leaves.count ?? 0) > 1
        case #selector(closeTab(_:)):
            item.title = (workspace.currentTree?.leaves.count ?? 0) > 1 ? "Close Pane" : "Close Tab"
            return true
        default:
            return true
        }
    }
}
