import AppKit
import Core
import Testing
@testable import App

/// One modifier, chosen in Settings, for every shortcut.
@MainActor
struct ShortcutsTests {
    /// The whole chord, as the menu has it.
    private func keys(_ title: String) throws -> String {
        let entry = try #require(Shortcuts.entries().first { $0.title == title })
        return Shortcuts.glyphs(Shortcuts.modifier.union(ownModifiers(entry.keys))) + entry.keys
            .unicodeScalars.filter { !"\u{2303}\u{2325}\u{21E7}\u{2318}".unicodeScalars.contains($0) }
            .map(String.init).joined()
    }

    private func ownModifiers(_ keys: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if keys.contains("\u{2303}") { flags.insert(.control) }
        if keys.contains("\u{2325}") { flags.insert(.option) }
        if keys.contains("\u{21E7}") { flags.insert(.shift) }
        if keys.contains("\u{2318}") { flags.insert(.command) }
        return flags
    }

    @Test("one modifier moves them all and comes back")
    func oneModifierMovesThemAllAndComesBack() async throws {
        _ = NSApplication.shared
        Menu.install(appName: "Termther")
        let store = try Store(inMemory: true)

        // Rows show only their own keys; the modifier is shown once above.
        #expect(Shortcuts.entries().first { $0.title == "New Tab" }?.keys == "T")

        // ⌘ to start with; commands with ⌥ of their own just have it.
        #expect(try keys("New Tab") == "\u{2318}T")
        #expect(try keys("Next Tab") == "\u{2318}\u{2192}")
        #expect(try keys("Focus Mode") == "\u{2325}\u{2318}F")
        #expect(try keys("Split Down") == "\u{21E7}\u{2318}D")

        // ⌃⌘: each keeps its own extra key on top of it.
        #expect(Shortcuts.set([.control, .command], store: store) == nil)
        #expect(try keys("New Tab") == "\u{2303}\u{2318}T")
        #expect(try keys("Focus Mode") == "\u{2303}\u{2325}\u{2318}F")
        #expect(try keys("Go to Tab") == "\u{2303}\u{2318}1\u{2013}9")

        // Refused, and nothing moves: ⌃ alone is the shell's, ⇧ takes
        // macOS's screenshot keys. ⌃⌥ is fine.
        #expect(Shortcuts.set(.control, store: store) != nil)
        #expect(Shortcuts.set([.shift, .command], store: store) != nil)
        #expect(Shortcuts.modifier == [.control, .command])
        #expect(Shortcuts.refusal(of: [.control, .option]) == nil)

        // macOS's own Enter Full Screen is not listed as one of ours.
        #expect(!Shortcuts.entries().contains { $0.title.contains("Full Screen") })

        // A fresh start has ⌘; restoring puts ⌃⌘ back.
        try await Task.sleep(for: .milliseconds(100))   // the save is detached
        Shortcuts.set(Shortcuts.standard, store: try Store(inMemory: true))
        Menu.install(appName: "Termther")
        #expect(try keys("New Tab") == "\u{2318}T")
        await Shortcuts.restore(from: store)
        #expect(try keys("New Tab") == "\u{2303}\u{2318}T")
        Shortcuts.set(Shortcuts.standard, store: store)
    }
}
