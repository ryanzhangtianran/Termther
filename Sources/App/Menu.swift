import AppKit

/// The menu bar.
///
/// Not decoration: on macOS the menu is what routes ⌘C, ⌘V and ⌘A. Without an
/// Edit menu carrying those key equivalents, the events reach the view as
/// ordinary key presses and ⌘C types the letter "c".
enum Menu {
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
        let focus = NSMenuItem(title: "Focus Mode",
                               action: #selector(WorkspaceCommands.toggleFocusMode(_:)),
                               keyEquivalent: "f")
        focus.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(focus)
        viewMenu.addItem(.separator())

        // ⌥⌘P, beside Focus Mode: both are things you flip while working
        // rather than set up once.
        let proxy = NSMenuItem(title: "Proxy Local Terminals",
                               action: #selector(WorkspaceCommands.toggleLocalProxy(_:)),
                               keyEquivalent: "p")
        proxy.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(proxy)
        viewMenu.addItem(.separator())

        let next = NSMenuItem(title: "Next Tab",
                              action: #selector(WorkspaceCommands.nextTab(_:)),
                              keyEquivalent: "\u{f703}")
        next.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(next)
        let previous = NSMenuItem(title: "Previous Tab",
                                  action: #selector(WorkspaceCommands.previousTab(_:)),
                                  keyEquivalent: "\u{f702}")
        previous.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(previous)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

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
    func toggleLocalProxy(_ sender: Any?)
}
