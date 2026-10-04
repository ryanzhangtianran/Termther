import AppKit
import Core
import SSH
import Net
import Observation
import SwiftUI
import VT

/// The window's terminals and which one is showing.
@MainActor
@Observable
final class Workspace {
    /// A tab is not always a terminal.
    ///
    /// Settings opens here rather than in a window or a side panel, so closing
    /// it and switching to it are the same gestures as everything else.
    enum Tab: Identifiable {
        case terminal(SplitTree)
        case settings

        var id: String {
            switch self {
            case .terminal(let tree): tree.id.uuidString
            case .settings: "settings"
            }
        }

        // A terminal's title comes from a main-actor object, so reading it is
        // main-actor work too.
        @MainActor
        var title: String {
            switch self {
            case .terminal(let tree):
                tree.leaves.count > 1
                    ? "\(tree.focused.title) \u{b7} \(tree.leaves.count) panes" : tree.focused.title
            case .settings: "Settings"
            }
        }

        /// The terminal the tab speaks for: the pane with the keyboard.
        @MainActor
        var session: TerminalSession? { tree?.focused }

        @MainActor
        var tree: SplitTree? {
            switch self {
            case .terminal(let tree): tree
            case .settings: nil
            }
        }
    }

    /// What a terminal tab shows: one shell, or shells beside and below one
    /// another. A split lays its two halves out along `axis` -- side by side
    /// for `.horizontal` -- with the first taking `fraction` of the room.
    indirect enum Pane {
        case leaf(TerminalSession)
        case split(axis: Axis, first: Pane, second: Pane, fraction: CGFloat)

        /// A divider stays clear of the edges: a pane squeezed to nothing
        /// cannot be found again to widen.
        static func clamped(_ fraction: CGFloat) -> CGFloat { min(max(fraction, 0.15), 0.85) }

        /// Every terminal, left to right and top to bottom.
        var leaves: [TerminalSession] {
            switch self {
            case .leaf(let session): [session]
            case .split(_, let first, let second, _): first.leaves + second.leaves
            }
        }

        /// The tree with `session`'s pane swapped for `pane`.
        func replacing(_ session: TerminalSession, with pane: Pane) -> Pane {
            switch self {
            case .leaf(let leaf): leaf === session ? pane : self
            case .split(let axis, let first, let second, let fraction):
                .split(axis: axis, first: first.replacing(session, with: pane),
                       second: second.replacing(session, with: pane), fraction: fraction)
            }
        }

        /// The tree without `session`, its neighbour taking the room; nil when
        /// it was all there was.
        func removing(_ session: TerminalSession) -> Pane? {
            switch self {
            case .leaf(let leaf): return leaf === session ? nil : self
            case .split(let axis, let first, let second, let fraction):
                guard let first = first.removing(session) else { return second }
                guard let second = second.removing(session) else { return first }
                return .split(axis: axis, first: first, second: second, fraction: fraction)
            }
        }

        /// The same panes, each given an equal share: three in a row are
        /// thirds, not a half and two quarters.
        func equalized() -> Pane {
            switch self {
            case .leaf: self
            case .split(let axis, let first, let second, _):
                .split(axis: axis, first: first.equalized(), second: second.equalized(),
                       fraction: first.count(along: axis) / (first.count(along: axis) + second.count(along: axis)))
            }
        }

        /// How many panes wide (or tall) the tree is.
        private func count(along axis: Axis) -> CGFloat {
            switch self {
            case .leaf: 1
            case .split(let own, let first, let second, _):
                own == axis ? first.count(along: axis) + second.count(along: axis)
                            : max(first.count(along: axis), second.count(along: axis))
            }
        }
    }

    /// A terminal tab's panes, and which of them has the keyboard.
    @MainActor
    @Observable
    final class SplitTree {
        let id = UUID()
        var root: Pane
        /// The pane keys go to, and the one the tab's row speaks for.
        var focused: TerminalSession

        init(_ session: TerminalSession) {
            root = .leaf(session)
            focused = session
        }

        var leaves: [TerminalSession] { root.leaves }
    }

    private(set) var tabs: [Tab] = []
    var selection: Tab.ID? {
        didSet { markSelected() }
    }
    /// Which page Settings shows; the sidebar lists them while it is open.
    var settingsPage: SettingsPage = .general
    /// The tab Settings was opened from, which closing it returns to.
    private var beforeSettings: Tab.ID?

    /// Everything but the terminals and their tabs is hidden.
    ///
    /// Not full screen: the window keeps its size and its buttons, so it can
    /// still sit beside something else. What goes is the chrome that is only
    /// useful between tasks -- the activity bar, the panel, the title strip.
    var isFocusMode = false

    /// Every pane of every tab.
    var sessions: [TerminalSession] { tabs.flatMap { $0.tree?.leaves ?? [] } }

    /// Rebuilt when the font setting changes, so every new terminal measures
    /// the grid the same way.
    var fonts = FontStack(size: 13)
    /// Applied to new terminals, and pushed to existing ones on a change.
    var palette: Palette = .kanagawaWave

    /// The pane with the keyboard in the tab showing.
    var current: TerminalSession? { currentTree?.focused }

    var currentTree: SplitTree? {
        tabs.first { $0.id == selection }?.tree
    }

    init() {
        // Looked at again: a tab left showing while the window was not key.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markSelected() }
        }
    }

    /// Tells each terminal whether it is the one being looked at: in the
    /// tab showing, and the pane with the keyboard.
    private func markSelected() {
        for tree in tabs.compactMap(\.tree) {
            for session in tree.leaves {
                session.isSelected = tree.id.uuidString == selection && session === tree.focused
            }
        }
    }

    /// Connects to a saved server in a new tab.
    ///
    /// The tab appears immediately, showing the connection being made: a
    /// terminal that takes a moment to answer is normal, and a spinner in a
    /// dialog would hide the reason when it fails.
    func open(_ server: Server, using model: AppModel) {
        let session = open(title: server.displayName, io: PendingRemote(server: server, model: model))
        session?.serverID = server.id
        session?.startsProxied = Self.startsProxied(server, model)
    }

    /// The same test `remoteShellCommand` makes for the exports.
    private static func startsProxied(_ server: Server, _ model: AppModel) -> () -> Bool {
        { [weak model] in server.id.flatMap { model?.forwards.runningProxyBack(for: $0) } != nil }
    }

    @discardableResult
    func newLocalTab() -> TerminalSession? {
        // Renamed to its directory once the shell has drawn a prompt.
        open(title: "Local", io: LocalShell())
    }

    /// A local tab that runs `command` in `directory` first -- an agent's
    /// session resumed -- and is an ordinary shell there once it ends.
    @discardableResult
    func openLocal(title: String, command: String, directory: String?) -> TerminalSession? {
        open(title: title, io: LocalShell(command: command, directory: directory))
    }

    @discardableResult
    func open(title: String, io: any SessionIO) -> TerminalSession? {
        guard let session = makeSession(title: title, io: io) else { return nil }
        let tree = SplitTree(session)
        tabs.append(.terminal(tree))
        selection = tree.id.uuidString
        Task { await session.start() }
        return session
    }

    private func makeSession(title: String, io: any SessionIO) -> TerminalSession? {
        guard let session = try? TerminalSession(title: title, io: io,
                                                 fonts: fonts, palette: palette) else {
            return nil
        }
        // A pane that closes itself when its shell exits: leaving a dead
        // terminal on screen is only ever confusing. (A lost SSH link is
        // not an exit; the session keeps that pane to reconnect in.)
        session.onExit = { [weak self, weak session] in
            guard let session else { return }
            self?.close(session)
        }
        session.view.onFocus = { [weak self, weak session] in
            guard let session else { return }
            self?.focus(session)
        }
        return session
    }

    // MARK: - panes

    /// Puts a new shell beside the pane with the keyboard (`.horizontal`) or
    /// below it (`.vertical`), and gives it the keyboard.
    @discardableResult
    func split(_ axis: Axis, title: String, io: any SessionIO) -> TerminalSession? {
        guard let tree = currentTree, let session = makeSession(title: title, io: io) else { return nil }
        tree.root = tree.root.replacing(tree.focused, with: .split(
            axis: axis, first: .leaf(tree.focused), second: .leaf(session), fraction: 0.5))
        focus(session)
        Task { await session.start() }
        return session
    }

    /// The same, with a shell like the focused pane's: a local one starts
    /// in its directory, and an SSH one connects to its server again.
    @discardableResult
    func split(_ axis: Axis, using model: AppModel) -> TerminalSession? {
        guard let current else { return nil }
        if let id = current.serverID, let server = model.servers.first(where: { $0.id == id }) {
            let session = split(axis, title: server.displayName, io: PendingRemote(server: server, model: model))
            session?.serverID = id
            session?.startsProxied = Self.startsProxied(server, model)
            return session
        }
        return split(axis, title: "Local", io: LocalShell(directory: current.workingDirectory))
    }

    /// Gives a pane the keyboard: its terminal was clicked, or a command
    /// asked for it.
    func focus(_ session: TerminalSession) {
        guard let tree = tree(holding: session) else { return }
        tree.focused = session
        markSelected()
    }

    /// The keyboard moves to the next pane along, or back, round the tab.
    func focusPane(by offset: Int) {
        guard let tree = currentTree,
              let index = tree.leaves.firstIndex(where: { $0 === tree.focused })
        else { return }
        let leaves = tree.leaves
        focus(leaves[(index + offset + leaves.count) % leaves.count])
    }

    func equalizePanes() {
        guard let tree = currentTree else { return }
        tree.root = tree.root.equalized()
    }

    private func tree(holding session: TerminalSession) -> SplitTree? {
        tabs.lazy.compactMap(\.tree).first { $0.leaves.contains { $0 === session } }
    }

    func openSettings() {
        if !tabs.contains(where: { if case .settings = $0 { true } else { false } }) {
            tabs.append(.settings)
        }
        if selection != Tab.settings.id { beforeSettings = selection }
        selection = Tab.settings.id
    }

    /// Closes a pane, its neighbour taking the room; the last pane in a tab
    /// closes the tab.
    func close(_ session: TerminalSession) {
        guard let tree = tree(holding: session) else { return }
        guard let root = tree.root.removing(session) else { return close(tabID: tree.id.uuidString) }
        let index = tree.leaves.firstIndex { $0 === session } ?? 0
        tree.root = root
        if tree.focused === session {
            // The neighbour, as closing a tab selects the one beside it.
            tree.focused = root.leaves[min(index, root.leaves.count - 1)]
        }
        markSelected()
        Task { await session.stop() }
    }

    func close(tabID: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let removed = tabs.remove(at: index)
        for session in removed.tree?.leaves ?? [] { Task { await session.stop() } }

        if selection == tabID {
            // Settings goes back to where it was opened from; any other tab
            // selects its neighbour, the way every tabbed app does.
            if tabID == Tab.settings.id, let back = beforeSettings, tabs.contains(where: { $0.id == back }) {
                selection = back
            } else {
                selection = tabs[safe: index]?.id ?? tabs.last?.id
            }
        }
    }

    /// ⌘W: the pane with the keyboard, which is the tab when it is the only one.
    func closeCurrent() {
        if let current { close(current) } else if let selection { close(tabID: selection) }
    }

    func selectTab(at index: Int) {
        guard let tab = tabs[safe: index] else { return }
        selection = tab.id
    }

    func selectNext(by offset: Int) {
        guard !tabs.isEmpty,
              let index = tabs.firstIndex(where: { $0.id == selection })
        else { return }
        let next = (index + offset + tabs.count) % tabs.count
        selection = tabs[next].id
    }

    /// Adopts a changed appearance: existing terminals are re-coloured in
    /// place, and the font is picked up by whatever opens next.
    ///
    /// A running terminal keeps its font: the grid it has already drawn is
    /// sized to it, and re-measuring would reflow live output under the cursor.
    func adopt(_ theme: Theme) {
        palette = theme.palette
        let updated = FontStack(name: theme.terminalFontFamily, size: theme.terminalFontSize,
                                weight: theme.terminalFontWeight,
                                lineHeight: theme.terminalLineHeight,
                                letterSpacing: theme.terminalLetterSpacing)
        // Only when the cells really change: a new renderer compiles its
        // shaders, which is not worth doing for every palette pick.
        let fontsChanged = updated.metrics != fonts.metrics
            || updated.resolvedName != fonts.resolvedName || updated.weight != fonts.weight
            || updated.thickens != fonts.thickens
        fonts = updated
        for session in sessions {
            session.apply(theme.palette)
            if fontsChanged { session.view.setFonts(updated) }
        }
    }

    func closeAll() async {
        let all = sessions
        tabs = []
        for session in all { await session.stop() }
    }
}

/// Resolves the route and credentials at connect time, then behaves as the
/// remote shell it stands in for.
///
/// Doing this here rather than before the tab opens means the work -- which may
/// involve dialling a jump host, or a VPN -- happens with somewhere to report
/// it, and the tab is on screen while it goes on.
///
/// An actor because a terminal drives its IO from whatever task has bytes to
/// send. An earlier version kept the resolved shell on the model and reached
/// for it with `MainActor.assumeIsolated`, which is not a check but an
/// assertion: the first keystroke arriving off the main actor took the process
/// down.
private actor PendingRemote: SessionIO {
    private let server: Server
    private let model: AppModel
    private var shell: RemoteShell?
    /// Closed before the connection was up: whatever comes up is let go.
    private var isStopped = false

    init(server: Server, model: AppModel) {
        self.server = server
        self.model = model
    }

    /// Called again to reconnect after the link died: the route is resolved
    /// afresh, and the dead shell is let go of.
    func start(cols: UInt16, rows: UInt16,
               onOutput: @escaping @Sendable ([UInt8]) -> Void,
               onExit: @escaping @Sendable (_ lost: Bool) -> Void) async throws {
        await shell?.stop()
        let shell = try await model.session(for: server)
        guard !isStopped else { return }
        self.shell = shell
        try await shell.start(cols: cols, rows: rows, onOutput: onOutput, onExit: onExit)
        // The tab closed while this logged in; a shell nobody can see stays
        // logged in on the server otherwise.
        if isStopped { await shell.stop() }
    }

    func send(_ bytes: [UInt8]) async { await shell?.send(bytes) }
    func resize(cols: UInt16, rows: UInt16) async { await shell?.resize(cols: cols, rows: rows) }
    func stop() async {
        isStopped = true
        await shell?.stop()
    }
    func isAtPrompt() async -> Bool? { await shell?.isAtPrompt() }
    func traffic() async -> TrafficCounter? { await shell?.traffic() }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
