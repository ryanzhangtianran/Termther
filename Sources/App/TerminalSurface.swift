import AppKit
import Core
import SwiftUI
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

    /// Types a line into the session, as if it had been entered.
    func type(_ line: String) {
        let io = self.io
        Task { await io.send(Array((line + "\n").utf8)) }
    }

    /// What the tab shows. Follows the shell's own title when it sets one.
    var title: String
    private(set) var hasExited = false

    /// Called when the far end goes away, so the workspace can close the tab.
    var onExit: (() -> Void)?

    private let terminal: Terminal

    init(title: String, io: any SessionIO, fonts: FontStack, palette: Palette,
         cursorStyle: CursorStyle = .bar) throws {
        self.title = title
        self.io = io

        let renderer = try CellRenderer(fonts: fonts, scale: NSScreen.main?.backingScaleFactor ?? 2)
        let terminal = try Terminal(cols: 100, rows: 30)
        self.terminal = terminal
        view = TerminalView(terminal: terminal, renderer: renderer)
        Task {
            await terminal.apply(palette)
            await terminal.setDefaultCursor(cursorStyle)
        }

        view.onInput = { bytes in Task { await io.send(bytes) } }
        view.onResize = { cols, rows in Task { await io.resize(cols: cols, rows: rows) } }
    }

    func start() async {
        do {
            try await io.start(cols: 100, rows: 30) { [weak self] bytes in
                Task { @MainActor in self?.view.write(bytes) }
            } onExit: { [weak self] in
                Task { @MainActor in
                    self?.hasExited = true
                    self?.onExit?()
                }
            }
        } catch {
            // Surfaced in the terminal itself, where the user is already
            // looking, rather than in an alert they have to dismiss.
            view.write(Array("\r\n\u{1b}[31mconnection failed:\u{1b}[0m \(error)\r\n".utf8))
        }
    }

    /// Re-colours a terminal that is already running.
    func apply(_ palette: Palette, cursor: CursorStyle) {
        Task {
            await terminal.apply(palette)
            await terminal.setDefaultCursor(cursor)
        }
    }

    func stop() async {
        view.stop()
        await io.stop()
    }
}
