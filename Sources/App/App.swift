import AppKit
import Core
import SwiftUI
import Net
import SwiftUI
import VT

@MainActor
public final class TermtherApp: NSObject, NSApplicationDelegate, WorkspaceCommands {
    private let theme = Theme()
    private let model = AppModel()
    // Nothing is opened until the saved appearance is back: a terminal built
    // before then measures its grid with the default font and keeps it, which
    // is why the first tab used to come up the wrong size while ⌘T was fine.
    private let workspace = Workspace(openingLocalTab: false)
    private var window: NSWindow!
    private var isTerminating = false
    private var hasAnsweredTerminate = false

    /// A session to open instead of a local shell, when launched with `ssh`.
    public var initialRemote: (title: String, io: any SessionIO)?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Menu.install(appName: "Termther")

        // Said once at startup, because a missing switch and an unbuilt
        // feature look identical from the settings page.
        let methods = QuickUnlock.methodsDescription()
        FileHandle.standardError.write(Data(
            ("termther: unlock-with-mac: \(methods ?? "unavailable")"
             + (QuickUnlock.lastAvailabilityError.map { " (\($0))" } ?? "")
             + ", enrolled=\(QuickUnlock.isEnrolled())\n").utf8))

        model.theme = theme
        model.onAppearanceChanged = { [weak self] in
            guard let self else { return }
            workspace.adopt(theme)
            // Set on the window, not the application: NSApp.appearance would
            // drag every panel and menu along with the terminal's colours.
            window.appearance = theme.appearance
        }
        Task {
            await model.restoreAppearance()
            if let remote = initialRemote {
                workspace.open(title: remote.title, io: remote.io)
            } else {
                workspace.newLocalTab()
            }
            focusCurrentTerminal()
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Termther"
        window.titlebarAppearsTransparent = true
        // The title would otherwise draw on top of the cards; the traffic
        // lights stay, and the strip they sit in stays draggable.
        window.titleVisibility = .hidden
        window.appearance = theme.appearance
        let hosting = NSHostingView(
            rootView: WorkspaceView(workspace: workspace, model: model)
                .environment(theme)
                .themed(theme))
        // The transparent titlebar still creates a safe area, which pushes the
        // whole layout down by its height -- and with it the title strip that
        // is supposed to line up with the window's own buttons.
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.center()
        // The cards are inset to wherever AppKit put the close button, so their
        // left edge and the buttons' line up exactly.
        if let close = window.standardWindowButton(.closeButton) {
            theme.windowButtonInset = close.frame.minX
        }

        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
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
        // they come back on the way out.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = workspace.isFocusMode
        }
        focusCurrentTerminal()
    }

    /// Sends this machine's terminals through the proxy, or stops.
    ///
    /// New terminals get the environment at birth. The one in front of you
    /// cannot -- a process has the environment it started with, and nothing
    /// reaches in to change that -- so the same line is typed into it. Visible
    /// on purpose: something really did happen to that shell.
    public func toggleLocalProxy(_ sender: Any?) {
        let line = model.localProxy.toggle()
        if let session = workspace.current, session.isLocal { session.type(line) }
        if let item = sender as? NSMenuItem {
            item.state = model.localProxy.isOn ? .on : .off
        }
        focusCurrentTerminal()
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
