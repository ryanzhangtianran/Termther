import Core
import SwiftUI
import Testing
import VT
@testable import App

/// Bytes go nowhere: the panes, or the terminal, are the thing under test.
struct NoIO: SessionIO {
    func start(cols: UInt16, rows: UInt16,
               onOutput: @escaping @Sendable ([UInt8]) -> Void,
               onExit: @escaping @Sendable (_ lost: Bool) -> Void) async throws {}
    func send(_ bytes: [UInt8]) async {}
    func resize(cols: UInt16, rows: UInt16) async {}
    func stop() async {}
    func isAtPrompt() async -> Bool? { nil }
}

/// A tab's terminals beside and below one another, and the keyboard among them.
@MainActor
struct PaneTests {
    /// One tab, with `count` panes from one shell split to the right.
    private func workspace(panes count: Int) throws -> (Workspace, [TerminalSession]) {
        let workspace = Workspace()
        var sessions = [try #require(workspace.open(title: "a", io: NoIO()))]
        for _ in 1..<count {
            sessions.append(try #require(workspace.split(.horizontal, title: "b", io: NoIO())))
        }
        return (workspace, sessions)
    }

    @Test("splitting a tab makes two panes and gives the new one the keyboard")
    func splittingMakesTwoPanes() async throws {
        let (workspace, sessions) = try workspace(panes: 2)
        #expect(workspace.tabs.count == 1)
        #expect(workspace.currentTree?.leaves.map(\.id) == sessions.map(\.id))
        #expect(workspace.current === sessions[1])
        #expect(!sessions[0].isSelected)
        #expect(sessions[1].isSelected)
        #expect(workspace.tabs[0].title == "b \u{b7} 2 panes")
        await workspace.closeAll()
    }

    @Test("the keyboard goes round the panes, forward and back")
    func focusGoesRound() async throws {
        let (workspace, sessions) = try workspace(panes: 3)
        #expect(workspace.current === sessions[2])
        workspace.focusPane(by: 1)
        #expect(workspace.current === sessions[0])
        workspace.focusPane(by: -1)
        #expect(workspace.current === sessions[2])
        workspace.focusPane(by: -1)
        #expect(workspace.current === sessions[1])
        #expect(sessions.map(\.isSelected) == [false, true, false])
        await workspace.closeAll()
    }

    @Test("closing the focused pane leaves its neighbour the keyboard and the tab open")
    func closingAPaneKeepsTheTab() async throws {
        let (workspace, sessions) = try workspace(panes: 2)
        workspace.closeCurrent()
        #expect(workspace.tabs.count == 1)
        #expect(workspace.currentTree?.leaves.count == 1)
        #expect(workspace.current === sessions[0])
        #expect(sessions[0].isSelected)
        #expect(workspace.tabs[0].title == "a")
        await workspace.closeAll()
    }

    @Test("closing the last pane closes the tab")
    func closingTheLastPaneClosesTheTab() async throws {
        let (workspace, _) = try workspace(panes: 2)
        workspace.closeCurrent()
        workspace.closeCurrent()
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.current == nil)
    }

    @Test("sessions lists every pane of every tab")
    func sessionsListsEveryPane() async throws {
        let (workspace, first) = try workspace(panes: 2)
        let second = try #require(workspace.open(title: "c", io: NoIO()))
        let below = try #require(workspace.split(.vertical, title: "d", io: NoIO()))
        #expect(workspace.sessions.map(\.id) == (first + [second, below]).map(\.id))
        #expect(workspace.tabs.count == 2)
        await workspace.closeAll()
    }

    @Test("a divider stays clear of the edges")
    func dividerStaysClearOfTheEdges() {
        #expect(Workspace.Pane.clamped(0.01) == 0.15)
        #expect(Workspace.Pane.clamped(0.99) == 0.85)
        #expect(Workspace.Pane.clamped(0.4) == 0.4)
    }

    @Test("equalized panes share the room evenly, nested or not")
    func equalizedPanesShareTheRoom() async throws {
        let (workspace, _) = try workspace(panes: 3)
        workspace.equalizePanes()
        guard case .split(_, .leaf, .split, let fraction)? = workspace.currentTree?.root else {
            Issue.record("expected a leaf beside a split")
            return
        }
        #expect(abs(fraction - 1 / 3) < 0.001)
        await workspace.closeAll()
    }
}
