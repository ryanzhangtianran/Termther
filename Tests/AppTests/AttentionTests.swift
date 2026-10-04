import Core
import Testing
import VT
@testable import App

/// A tab that is not showing says so in the sidebar when its program rings
/// the bell -- Claude Code, waiting for an answer -- and stops saying so once
/// it is looked at.
@MainActor
@Test("a bell in a tab that is not selected asks for attention, until it is selected")
func bellAsksForAttentionUntilSelected() async throws {
    let session = try TerminalSession(title: "t", io: NoIO(),
                                      fonts: FontStack(size: 13), palette: .kanagawaWave)
    await session.start()
    #expect(!session.needsAttention)

    session.view.write([0x07])
    for _ in 0..<50 where !session.needsAttention {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(session.needsAttention)

    session.isSelected = true
    #expect(!session.needsAttention)
    await session.stop()
}
