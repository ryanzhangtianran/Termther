import AppKit
import Core

/// The menu bar.
///
/// Not decoration: on macOS the menu is what routes ⌘C, ⌘V and ⌘A. Without an
/// Edit menu carrying those key equivalents, the events reach the view as
/// ordinary key presses and ⌘C types the letter "c".
enum Menu {
    /// The bar as built, whether or not AppKit is running to show it.
    @MainActor private(set) static var bar: NSMenu?

    @MainActor
    static func install(appName: String) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(WorkspaceCommands.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(WorkspaceCommands.closeTab(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Sent down the responder chain to whichever terminal has focus.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "Find\u{2026}",
                         action: #selector(WorkspaceCommands.find(_:)), keyEquivalent: "f")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for index in 1...9 {
            let item = NSMenuItem(title: "Tab \(index)",
                                  action: #selector(WorkspaceCommands.selectTab(_:)),
                                  keyEquivalent: String(index))
            item.tag = index - 1
            item.isHidden = index > 4      // the rest still work, just unlisted
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        // An item's key is on ⌘ unless said otherwise.
        viewMenu.addItem(withTitle: "Focus Mode",
                         action: #selector(WorkspaceCommands.toggleFocusMode(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())

        // ⌘P, beside Focus Mode: both are things you flip while working
        // rather than set up once.
        viewMenu.addItem(withTitle: "Proxy This Terminal",
                         action: #selector(WorkspaceCommands.toggleLocalProxy(_:)), keyEquivalent: "p")
        // No key: on ⌘ it would be Paste's.
        viewMenu.addItem(withTitle: "Connect VPN",
                         action: #selector(WorkspaceCommands.toggleVPN(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())

        // ⌘ rather than ⌃: macOS keeps ⌃← and ⌃→ for switching Spaces.
        viewMenu.addItem(withTitle: "Next Tab",
                         action: #selector(WorkspaceCommands.nextTab(_:)), keyEquivalent: "\u{f703}")
        viewMenu.addItem(withTitle: "Previous Tab",
                         action: #selector(WorkspaceCommands.previousTab(_:)), keyEquivalent: "\u{f702}")
        viewMenu.addItem(.separator())

        // Panes, on the keys every terminal uses for them, under the one
        // modifier like the rest. (On ⌥⌘, Split Right lands on ⌥⌘D, which
        // macOS keeps for hiding the Dock unless that is turned off.)
        viewMenu.addItem(withTitle: "Split Right",
                         action: #selector(WorkspaceCommands.splitRight(_:)), keyEquivalent: "d")
        viewMenu.addItem(withTitle: "Split Down",
                         action: #selector(WorkspaceCommands.splitDown(_:)), keyEquivalent: "d")
            .keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: "Next Pane",
                         action: #selector(WorkspaceCommands.focusNextPane(_:)), keyEquivalent: "]")
        viewMenu.addItem(withTitle: "Previous Pane",
                         action: #selector(WorkspaceCommands.focusPreviousPane(_:)), keyEquivalent: "[")
        viewMenu.addItem(withTitle: "Equalize Panes",
                         action: #selector(WorkspaceCommands.equalizePanes(_:)), keyEquivalent: "=")
            .keyEquivalentModifierMask = [.command, .shift]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        bar = main
        Shortcuts.adopt(main)
        NSApp.mainMenu = main
    }
}

/// The actions the menu sends; the app delegate implements them.
///
/// Main-actor isolated because everything it touches is: menus, windows and
/// the terminals themselves.
@MainActor
@objc protocol WorkspaceCommands {
    func newTab(_ sender: Any?)
    func closeTab(_ sender: Any?)
    func selectTab(_ sender: Any?)
    func nextTab(_ sender: Any?)
    func previousTab(_ sender: Any?)
    func toggleFocusMode(_ sender: Any?)
    func splitRight(_ sender: Any?)
    func splitDown(_ sender: Any?)
    func focusNextPane(_ sender: Any?)
    func focusPreviousPane(_ sender: Any?)
    func equalizePanes(_ sender: Any?)
    func toggleLocalProxy(_ sender: Any?)
    func toggleVPN(_ sender: Any?)
    func find(_ sender: Any?)
}

/// The menus' shortcuts, on the one modifier chosen for all of them.
///
/// One choice rather than one per command: what people change is which keys
/// their shortcuts live on, not each chord. ⌥⌘ by default, clear of the ⌘
/// shortcuts every other app has. A command with a key of its own keeps it
/// on top: Focus Mode adds ⌥ to whatever is chosen.
@MainActor
enum Shortcuts {
    struct Entry: Identifiable {
        let title: String
        let keys: String
        var id: String { title }
    }

    /// ⌘ alone, as every other app: the shell never sees a ⌘ chord, so
    /// there is nothing to keep clear of.
    static let standard: NSEvent.ModifierFlags = .command

    /// The one in use.
    private(set) static var modifier: NSEvent.ModifierFlags = standard

    /// Why these cannot be the modifier, or nil when they can.
    static func refusal(of modifier: NSEvent.ModifierFlags) -> String? {
        // ⌃ or ⌥ alone are the shell's -- ⌃W deletes a word, ⌥B goes back
        // one -- and would stop reaching it.
        guard modifier.contains(.command) || modifier.isSuperset(of: [.control, .option]) else {
            return "Needs \u{2318}, or \u{2303} with \u{2325}"
        }
        // ⇧⌘ with Go to Tab's digits is macOS's own: ⇧⌘3, 4 and 5 are its
        // screenshots, and would stop reaching it.
        guard !modifier.contains(.shift) else { return "\u{21E7} would take macOS's screenshot keys" }
        return nil
    }

    /// Each command's shortcut as the menu defines it, on ⌘.
    private static var defaults: [Selector: NSEvent.ModifierFlags] = [:]

    /// Reads the defaults off a freshly built menu and puts the chosen
    /// modifier on it. Items macOS adds afterwards -- Enter Full Screen --
    /// are its own and left alone.
    static func adopt(_ bar: NSMenu) {
        defaults = [:]
        for item in shortcutItems(of: bar) {
            if let action = item.action { defaults[action] = relevant(item.keyEquivalentModifierMask) }
        }
        applyToMenu()
    }

    /// Moves every shortcut onto `modifier`, or says why not.
    @discardableResult
    static func set(_ modifier: NSEvent.ModifierFlags, store: Store) -> String? {
        let modifier = relevant(modifier)
        if let refusal = refusal(of: modifier) { return refusal }
        self.modifier = modifier
        applyToMenu()
        Task { try? await store.setSetting(settingKey, to: String(modifier.rawValue)) }
        return nil
    }

    /// Puts back the one chosen, over the standard one.
    static func restore(from store: Store) async {
        guard let saved = try? await store.setting(settingKey), let raw = UInt(saved) else { return }
        let modifier = NSEvent.ModifierFlags(rawValue: raw)
        guard refusal(of: modifier) == nil else { return }
        self.modifier = modifier
        applyToMenu()
    }

    /// One row per command, keys past the shared modifier; the nine
    /// numbered tabs are one row.
    static func entries() -> [Entry] {
        var seen = Set<Selector>()
        return items.compactMap { item in
            guard let action = item.action, seen.insert(action).inserted else { return nil }
            let isTabs = action == #selector(WorkspaceCommands.selectTab(_:))
            let key = isTabs ? "1\u{2013}9" : glyph(of: item.keyEquivalent)
            // The shared modifier is shown once, above the list; each row
            // has only what is its own.
            let own = relevant(item.keyEquivalentModifierMask).subtracting(modifier)
            return Entry(title: isTabs ? "Go to Tab" : item.title, keys: glyphs(own) + key)
        }
    }

    /// In the order macOS writes them: ⌃ ⌥ ⇧ ⌘.
    static func glyphs(_ modifiers: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "\u{2303}"), (.option, "\u{2325}"),
         (.shift, "\u{21E7}"), (.command, "\u{2318}")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined()
    }

    private static let settingKey = "shortcutModifier"

    private static func applyToMenu() {
        for item in items {
            guard let action = item.action, let own = defaults[action] else { continue }
            item.keyEquivalentModifierMask = own.subtracting(.command).union(modifier)
        }
    }

    /// Ours: the File and View menus' items with a key, as built.
    private static var items: [NSMenuItem] {
        Menu.bar.map(shortcutItems(of:))?.filter { $0.action.map { defaults[$0] != nil } ?? false } ?? []
    }

    /// Edit and the app menu are left out: ⌘C, ⌘V and ⌘Q are the same in
    /// every Mac app.
    private static func shortcutItems(of bar: NSMenu) -> [NSMenuItem] {
        bar.items.compactMap(\.submenu)
            .filter { ["File", "View"].contains($0.title) }
            .flatMap(\.items)
            .filter { !$0.keyEquivalent.isEmpty && $0.action != nil }
    }

    private static func relevant(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection([.control, .option, .shift, .command])
    }

    private static func glyph(of key: String) -> String {
        switch key {
        case "\u{f700}": "\u{2191}"
        case "\u{f701}": "\u{2193}"
        case "\u{f702}": "\u{2190}"
        case "\u{f703}": "\u{2192}"
        default: key.uppercased()
        }
    }
}
