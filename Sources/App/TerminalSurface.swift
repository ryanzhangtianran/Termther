import AppKit
import Core
import SSH
import SwiftUI
import UserNotifications
import VT

/// Puts a `TerminalView` into SwiftUI.
///
/// The view is created once and handed back on every update: a terminal owns a
/// live pty and scrollback, so rebuilding it the way SwiftUI rebuilds most
/// views would throw away the session.
struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> TerminalView { session.view }

    func updateNSView(_ view: TerminalView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

/// One terminal: an emulator, a renderer, a view, and something feeding it.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let view: TerminalView
    private let io: any SessionIO

    /// True when this is a shell on this machine.
    ///
    /// The distinction matters for anything that reaches into the terminal:
    /// typing a line into a local shell changes this machine, and typing the
    /// same line into a remote one changes a server.
    var isLocal: Bool { io is LocalShell }

    /// Where a local shell is, asked of the kernel; nil for an SSH tab.
    var workingDirectory: String? { (io as? LocalShell)?.workingDirectory }

    /// The saved server an SSH tab is connected to.
    var serverID: Int64?

    /// Puts a local shell through the proxy, or takes it off.
    ///
    /// A running process keeps the environment it started with, so the
    /// shell has to run the exports itself. zsh does it unseen and at once,
    /// by way of the integration, prompt redrawn; any other shell has the
    /// line typed in.
    /// False, and nothing changed, when the line would have to be typed and
    /// the shell is not at its prompt.
    func setProxy(_ on: Bool, command: String) async -> Bool {
        guard let shell = io as? LocalShell else { return false }
        // zsh's integration takes it at its next prompt, whatever is running now.
        if !(shell.processID.map { ShellEnvironment.request(command, forShell: $0) } ?? false) {
            guard await typeAtPrompt(command) else { return false }
        }
        usesProxy = on
        return true
    }

    /// Set while a proxy switch is on its way, so a second click cannot read
    /// the same state and type the same line again.
    var isSwitchingProxy = false

    /// Types a line into the session, as if it had been entered.
    func type(_ line: String) {
        send(Array((line + "\n").utf8))
    }

    /// Whether the shell itself has the terminal; false when that cannot be told.
    func isAtPrompt() async -> Bool { await io.isAtPrompt() == true }

    /// Types a line only while the shell is at its prompt. Anywhere else it
    /// lands in whatever is running -- vim takes it as keystrokes.
    ///
    /// Whatever is half typed at the prompt is cleared first (^E^U, which it
    /// can be yanked back from with ^Y): the line would otherwise be run on
    /// the end of it. The leading space keeps it out of a history that
    /// ignores such lines.
    ///
    /// Typed unseen: the pty echoes what is typed, so the line starts by
    /// moving back up over its own echo and the prompt and clearing to the
    /// end of the screen. What follows -- an export, and the prompt drawn
    /// afresh; or a program taking the screen -- begins where the prompt was.
    func typeAtPrompt(_ line: String) async -> Bool {
        guard await isAtPrompt() else { return false }
        func typed(_ rows: Int) -> String { " printf '\\033[\(rows)A\\033[J'; \(line)" }
        var rows = await terminal.rowsToErase(afterTyping: typed(1).count)
        rows = await terminal.rowsToErase(afterTyping: typed(rows).count)
        type("\u{05}\u{15}" + typed(rows))
        return true
    }

    /// Everything bound for the shell, keystrokes, replies and sizes alike, in
    /// the order it was produced. A task each would let a keystroke overtake
    /// a paste still being written, or an older size land after a newer one.
    private enum Outgoing: Sendable {
        case bytes([UInt8])
        case resize(cols: UInt16, rows: UInt16)
    }
    @ObservationIgnored private let outgoing: AsyncStream<Outgoing>.Continuation

    private func send(_ bytes: [UInt8]) { outgoing.yield(.bytes(bytes)) }

    /// What the tab shows. Follows the shell's own title when it sets one.
    var title: String
    private(set) var hasExited = false
    /// An SSH tab whose link died: the shell is gone, the terminal is kept,
    /// and Enter dials again.
    private(set) var isDisconnected = false
    /// The shell asked for attention -- rang the bell, sent a notification --
    /// while the tab was not being looked at. Cleared once it is.
    private(set) var needsAttention = false
    /// Whether this is the tab showing; kept by the workspace, which marks it
    /// again whenever the window becomes key, so being marked is being looked at.
    var isSelected = false {
        didSet { if isSelected { needsAttention = false } }
    }
    @ObservationIgnored private var directoryCheck: Task<Void, Never>?

    /// Whether the shell has the proxy's variables. A local one starts with
    /// whatever new terminals get; either kind changes by its switch.
    var usesProxy = false

    /// An SSH tab's bandwidth over the last second, each way; nil for a
    /// local shell or one not connected.
    private(set) var rate: Forwards.Rate?
    @ObservationIgnored private var sampler: Task<Void, Never>?

    /// Called when the shell has ended for good, so the workspace can close
    /// the tab. An SSH tab whose link died is kept instead, disconnected.
    var onExit: (() -> Void)?

    private let terminal: Terminal

    /// The grid the view last measured. The shell starts at it rather than at
    /// a guess: started at 100 columns and narrowed a moment later, a long
    /// prompt is reflowed onto extra rows and then drawn again below them,
    /// leaving blank lines above the prompt in a half-screen window.
    @ObservationIgnored private var size: (cols: UInt16, rows: UInt16)?
    @ObservationIgnored private var sizeWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(title: String, io: any SessionIO, fonts: FontStack, palette: Palette) throws {
        self.title = title
        self.io = io
        usesProxy = io is LocalShell && LocalShell.newShellEnvironment["http_proxy"] != nil

        let renderer = try CellRenderer(fonts: fonts, scale: NSScreen.main?.backingScaleFactor ?? 2)
        let terminal = try Terminal(cols: 100, rows: 30)
        self.terminal = terminal
        view = TerminalView(terminal: terminal, renderer: renderer)
        let (queue, outgoing) = AsyncStream.makeStream(of: Outgoing.self)
        self.outgoing = outgoing
        Task {
            for await item in queue {
                switch item {
                case .bytes(let bytes): await io.send(bytes)
                case .resize(let cols, let rows): await io.resize(cols: cols, rows: rows)
                }
            }
        }
        Task {
            await terminal.apply(palette)
            await terminal.setDefaultCursor(.bar)
        }

        view.onInput = { [weak self] bytes in
            guard let self, isDisconnected else { outgoing.yield(.bytes(bytes)); return }
            if bytes == [0x0d] { Task { await self.reconnect() } }
        }
        view.onResize = { [weak self] cols, rows in self?.measured(cols: cols, rows: rows) }
    }

    private func measured(cols: UInt16, rows: UInt16) {
        size = (cols, rows)
        if hasStarted {
            outgoing.yield(.resize(cols: cols, rows: rows))
        } else {
            releaseSizeWaiter()
        }
    }

    private func releaseSizeWaiter() {
        sizeWaiter?.resume()
        sizeWaiter = nil
    }

    func start() async {
        // Until the first layout, briefly: a view that never measures (or
        // measures exactly the default) must not hold the shell back.
        if size == nil {
            await withCheckedContinuation { continuation in
                sizeWaiter = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.releaseSizeWaiter()
                }
            }
        }
        hasStarted = true
        // Before any output, so the first query is answered too.
        let outgoing = self.outgoing
        await terminal.onReply { bytes in outgoing.yield(.bytes(bytes)) }
        await terminal.onBell { [weak self] in Task { @MainActor in self?.attention("Bell") } }
        await terminal.onNotification { [weak self] title, body in
            Task { @MainActor in self?.attention(body.isEmpty ? title : body) }
        }
        await connect()
    }

    private func connect() async {
        let start = size ?? (cols: 100, rows: 30)
        do {
            try await io.start(cols: start.cols, rows: start.rows) { [weak self] bytes in
                Task { @MainActor in
                    self?.view.write(bytes)
                    self?.followDirectorySoon()
                }
            } onExit: { [weak self] lost in
                Task { @MainActor in self?.ended(lost: lost) }
            }
            // Measured again while it started: a local shell has no pty to
            // size until then, and would stay at the old size.
            if let size, size != start { outgoing.yield(.resize(cols: size.cols, rows: size.rows)) }
            // Asked of the session, not its type: an SSH tab's shell sits
            // behind the route that was resolved to reach it.
            if let traffic = await io.traffic(), !hasExited { sample(traffic) }
        } catch {
            // Surfaced in the terminal itself, where the user is already
            // looking, rather than in an alert they have to dismiss.
            view.write(Array("\r\n\u{1b}[31mconnection failed:\u{1b}[0m \(error)\r\n".utf8))
            if !isLocal { disconnected("Could not connect") }
        }
    }

    /// The shell is gone. A local one, or a remote one that exited, ends the
    /// tab; a remote one whose link died stays, to be dialled again.
    private func ended(lost: Bool) {
        guard !hasExited else { return }   // stopped on purpose; nothing to report
        forgetRequests()
        stopSampling()
        if lost, !isLocal {
            disconnected("Connection to \(title) lost")
        } else {
            hasExited = true
            onExit?()
        }
    }

    /// Says so in the terminal, and arms Enter. Whatever the last program
    /// left on -- the alternate screen, the mouse, the Kitty keyboard
    /// protocol -- is turned off first, or the line would land on a screen
    /// nobody sees and Enter would not arrive as Enter.
    private func disconnected(_ what: String) {
        isDisconnected = true
        Task { [terminal] in
            await terminal.write("\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l")
            await terminal.resetKeyboardProtocol()
            await terminal.write("\r\n\u{1b}[2m[\(what) \u{2014} press Enter to reconnect, or close the tab]\u{1b}[0m\r\n")
        }
    }

    /// Dials again, in this terminal: the route is resolved afresh, as it
    /// was the first time, and the new shell starts on a cleared screen at
    /// the current size.
    func reconnect() async {
        guard isDisconnected else { return }
        isDisconnected = false
        await terminal.write("\u{1b}[H\u{1b}[2J")
        await connect()
    }

    /// The shell asked for attention. Noted on the tab unless it is the one
    /// being looked at, and told to the system when the app is not in front.
    private func attention(_ body: String) {
        if !isSelected || view.window?.isKeyWindow != true { needsAttention = true }
        // Only from the app bundle: the notification centre traps without one,
        // and a test is not an app.
        guard NSApp?.isActive == false, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        // Asked every time; the system only ever prompts once.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A local tab is named after the directory its shell is in. Checked
    /// once output settles, which is when a `cd` redraws the prompt.
    private func followDirectorySoon() {
        guard let shell = io as? LocalShell else { return }
        directoryCheck?.cancel()
        directoryCheck = Task { [weak self, terminal] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let path = shell.workingDirectory else { return }
            self?.title = path == NSHomeDirectory()
                ? "~" : URL(fileURLWithPath: path).lastPathComponent
            // Back at the prompt, whatever the last program left the
            // keyboard in is undone.
            if await shell.isAtPrompt() == true { await terminal.resetKeyboardProtocol() }
        }
    }

    /// Re-colours a terminal that is already running.
    func apply(_ palette: Palette) {
        Task { await terminal.apply(palette) }
    }

    /// Once a second, the rate since the last look -- as the proxy page does
    /// for its tunnels.
    private func sample(_ traffic: TrafficCounter) {
        sampler = Task { [weak self] in
            var previous = traffic.statistics
            var then = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = ContinuousClock.now
                let current = traffic.statistics
                guard let self, !Task.isCancelled else { return }
                rate = Forwards.Rate.between(previous, current,
                                             seconds: (now - then) / .seconds(1))
                previous = current
                then = now
            }
        }
    }

    private func stopSampling() {
        sampler?.cancel()
        sampler = nil
        rate = nil
    }

    private func forgetRequests() {
        if let pid = (io as? LocalShell)?.processID { ShellEnvironment.forget(shell: pid) }
    }

    func stop() async {
        forgetRequests()
        stopSampling()
        hasExited = true
        view.stop()
        outgoing.finish()
        await io.stop()
    }
}
