import AppKit
import Core
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
        case terminal(TerminalSession)
        case settings

        var id: String {
            switch self {
            case .terminal(let session): session.id.uuidString
            case .settings: "settings"
            }
        }

        // A terminal's title comes from a main-actor object, so reading it is
        // main-actor work too.
        @MainActor
        var title: String {
            switch self {
            case .terminal(let session): session.title
            case .settings: "Settings"
            }
        }

        @MainActor
        var session: TerminalSession? {
            switch self {
            case .terminal(let session): session
            case .settings: nil
            }
        }
    }

    private(set) var tabs: [Tab] = []
    var selection: Tab.ID?

    /// Everything but the terminals and their tabs is hidden.
    ///
    /// Not full screen: the window keeps its size and its buttons, so it can
    /// still sit beside something else. What goes is the chrome that is only
    /// useful between tasks -- the activity bar, the panel, the title strip.
    var isFocusMode = false

    var sessions: [TerminalSession] { tabs.compactMap(\.session) }

    /// Rebuilt when the font setting changes, so every new terminal measures
    /// the grid the same way.
    var fonts = FontStack(size: 13)
    /// Applied to new terminals, and pushed to existing ones on a change.
    var palette: Palette = .kanagawaWave
    var cursorStyle: CursorStyle = .bar

    var current: TerminalSession? {
        tabs.first { $0.id == selection }?.session
    }

    init(openingLocalTab: Bool = true) {
        if openingLocalTab { newLocalTab() }
    }

    /// Connects to a saved server in a new tab.
    ///
    /// The tab appears immediately, showing the connection being made: a
    /// terminal that takes a moment to answer is normal, and a spinner in a
    /// dialog would hide the reason when it fails.
    func open(_ server: Server, using model: AppModel) {
        guard let session = try? TerminalSession(
            title: server.name.isEmpty ? server.host : server.name,
            io: PendingRemote(server: server, model: model),
            fonts: fonts, palette: palette, cursorStyle: cursorStyle)
        else { return }

        session.onExit = { [weak self, weak session] in
            guard let session else { return }
            self?.close(session)
        }
        tabs.append(.terminal(session))
        selection = session.id.uuidString
        Task { await session.start() }
    }

    @discardableResult
    func newLocalTab() -> TerminalSession? {
        open(title: "zsh", io: LocalShell())
    }

    @discardableResult
    func open(title: String, io: any SessionIO) -> TerminalSession? {
        guard let session = try? TerminalSession(title: title, io: io,
                                                 fonts: fonts, palette: palette,
                                                 cursorStyle: cursorStyle) else {
            return nil
        }
        // A tab that closes itself when its shell exits: leaving a dead
        // terminal on screen is only ever confusing.
        session.onExit = { [weak self, weak session] in
            guard let session else { return }
            self?.close(session)
        }
        tabs.append(.terminal(session))
        selection = session.id.uuidString
        Task { await session.start() }
        return session
    }

    /// Opens settings, or brings the existing tab forward. Only ever one.
    func openSettings() {
        if !tabs.contains(where: { if case .settings = $0 { true } else { false } }) {
            tabs.append(.settings)
        }
        selection = Tab.settings.id
    }

    func close(_ session: TerminalSession) {
        close(tabID: session.id.uuidString)
    }

    func close(tabID: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let removed = tabs.remove(at: index)
        if let session = removed.session { Task { await session.stop() } }

        if selection == tabID {
            // Select the neighbour, the way every tabbed app does.
            selection = tabs[safe: index]?.id ?? tabs.last?.id
        }
    }

    func closeCurrent() {
        guard let selection else { return }
        close(tabID: selection)
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
        cursorStyle = theme.cursorStyle
        fonts = FontStack(name: theme.terminalFontFamily, size: theme.terminalFontSize,
                          weight: theme.terminalFontWeight,
                          lineHeight: theme.terminalLineHeight,
                          letterSpacing: theme.terminalLetterSpacing)
        for session in sessions { session.apply(theme.palette, cursor: theme.cursorStyle) }
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

    init(server: Server, model: AppModel) {
        self.server = server
        self.model = model
    }

    func start(cols: UInt16, rows: UInt16,
               onOutput: @escaping @Sendable ([UInt8]) -> Void,
               onExit: @escaping @Sendable () -> Void) async throws {
        let shell = try await model.session(for: server)
        self.shell = shell
        try await shell.start(cols: cols, rows: rows, onOutput: onOutput, onExit: onExit)
    }

    func send(_ bytes: [UInt8]) async { await shell?.send(bytes) }
    func resize(cols: UInt16, rows: UInt16) async { await shell?.resize(cols: cols, rows: rows) }
    func stop() async { await shell?.stop() }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
