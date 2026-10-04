import AppKit
import Core
import SwiftUI
import VT

/// The General page: the terminal's look, where the app's files are, the
/// keys, unlocking, and the local shell's environment.
///
/// What is the app's rather than one feature's lives here. Moving a
/// location points the app somewhere else and moves nothing: the files
/// stay where they were.
struct GeneralSettings: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    @State private var shortcutsRevision = 0
    @State private var credentialCount = 0
    @State private var prunedMessage: String?
    /// Asked once for the page: each asking is three round trips to the
    /// system, and the body is redrawn on every tick of the sliders above.
    @State private var quickUnlockMethods = QuickUnlock.methodsDescription()

    var body: some View {
        @Bindable var theme = theme
        @Bindable var environment = model.shellEnvironment
        Section("Terminal") {
            LabeledContent("Theme") {
                HStack(spacing: 10) {
                    // The scheme's six colours, so the choice is seen and
                    // not only named.
                    HStack(spacing: 3) {
                        ForEach(1..<7) { index in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(theme.ansi(index))
                                .frame(width: 12, height: 12)
                        }
                    }
                    PopUpMenu(Palette.builtIn.map { ($0.name, $0.name) },
                              selection: Binding(
                        get: { theme.palette.name },
                        set: { name in
                            if let palette = Palette.builtIn.first(where: { $0.name == name }) {
                                model.apply(palette)
                            }
                        }))
                }
            }
            // A menu like the theme's, so every choice on the page looks
            // and opens the same way.
            LabeledContent("Font Size") {
                PopUpMenu((10...24).map { ("\($0) pt", CGFloat($0)) },
                          selection: $theme.terminalFontSize)
            }
            Multiplier(title: "Line Height", value: $theme.terminalLineHeight, range: 0.9...1.8)
            Multiplier(title: "Letter Spacing", value: $theme.terminalLetterSpacing, range: 0.9...1.6)
        }
        .onChange(of: theme.terminalFontSize) { model.saveTerminalLayoutSettings() }
        .onChange(of: theme.terminalLineHeight) { model.saveTerminalLayoutSettings() }
        .onChange(of: theme.terminalLetterSpacing) { model.saveTerminalLayoutSettings() }

        Section("Locations") {
            row("Data", .data)
            row("Keys", .keys)
            row("SSH Config", .sshConfig)
        }

        Section("Keyboard") {
            ModifierRecorder(store: model.store) { shortcutsRevision += 1 }
            // Read from the menus themselves, so the list cannot drift from
            // what the keys really do. Two to a row, each a pair of caps of
            // fixed widths, so the caps line up down both columns.
            let entries = Shortcuts.entries()
            ForEach(Array(stride(from: 0, to: entries.count, by: 2)), id: \.self) { start in
                HStack(spacing: 0) {
                    shortcut(entries[start])
                    Divider().opacity(0.5).padding(.horizontal, 18)
                    if start + 1 < entries.count { shortcut(entries[start + 1]) } else { Spacer() }
                }
            }
        }
        // The menus are not observed; this is what redraws.
        .id(shortcutsRevision)

        Section("Unlock") {
            // Off by default: the vault opens by itself. On, the Mac
            // confirms the owner each time Termther opens.
            if let methods = quickUnlockMethods {
                Toggle(isOn: Binding(
                    get: { model.requiresMacUnlock },
                    set: { wanted in Task { _ = await model.setRequiresMacUnlock(wanted) } })) {
                    Text("Require \(methods)")
                }
            } else {
                LabeledContent {
                    Text("Not Available")
                } label: {
                    Text("Unlock with This Mac")
                }
            }
            LabeledContent {
                HStack(spacing: 10) {
                    // A value, as the paths and versions on these pages are.
                    Text(prunedMessage ?? "\(credentialCount)")
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                    Button("Remove Unused") {
                        Task {
                            let removed = await model.pruneUnusedCredentials()
                            prunedMessage = removed == 0 ? "Nothing to remove" : "Removed \(removed)"
                            credentialCount = await model.credentialCount()
                        }
                    }
                    .buttonStyle(.plate)
                }
            } label: {
                Text("Keys and Passwords")
            }
        }
        .task { credentialCount = await model.credentialCount() }

        EnvironmentTable(title: "Local Environment", variables: $environment.variables)
    }

    private func shortcut(_ entry: Shortcuts.Entry) -> some View {
        HStack {
            Text(entry.title)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                KeyCap(text: Shortcuts.glyphs(Shortcuts.modifier), width: 52)
                KeyCap(text: entry.keys, width: 44)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ title: String, _ location: AppPaths.Location) -> some View {
        let url = model.paths[location]
        return LabeledContent {
            HStack(spacing: 8) {
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose") { model.choosePath(location) }
                    .buttonStyle(.plate)
                Button("Show in Finder") { show(url) }
                    .buttonStyle(.plate)
            }
        } label: {
            Text(title)
        }
    }

    /// A folder not there yet is made first, so Finder has something to show.
    private func show(_ url: URL) {
        if url.hasDirectoryPath {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension AppModel {
    /// Asks for a new place for one of General's locations; the SSH Config
    /// page asks the same way.
    func choosePath(_ location: AppPaths.Location) {
        let isFile = location == .sshConfig
        let panel = NSOpenPanel()
        panel.canChooseFiles = isFile
        panel.canChooseDirectories = !isFile
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = paths[location].deletingLastPathComponent()
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setPath(location, to: url) }
    }
}

/// The shortcuts' modifier, set by pressing it: click, hold the keys,
/// let go. Escape leaves it as it was.
private struct ModifierRecorder: View {
    @Environment(Theme.self) private var theme
    let store: Store
    let changed: () -> Void

    @State private var isRecording = false
    /// Every modifier held since recording began; a chord is let go of one
    /// key at a time, and it is the whole chord that is meant.
    @State private var pressed: NSEvent.ModifierFlags = []
    @State private var monitor: Any?
    @State private var refusal: String?

    var body: some View {
        LabeledContent {
            Button { if isRecording { stop() } else { start() } } label: {
                KeyCap(text: label, width: isRecording && pressed.isEmpty ? 104 : 52,
                       isDimmed: isRecording && pressed.isEmpty, isRecording: isRecording)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Modifier")
                if let refusal {
                    Text(refusal)
                        .font(theme.ui(12))
                        .foregroundStyle(.orange)
                }
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        guard isRecording else { return Shortcuts.glyphs(Shortcuts.modifier) }
        return pressed.isEmpty ? "Press keys\u{2026}" : Shortcuts.glyphs(pressed)
    }

    private func start() {
        refusal = nil
        pressed = []
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            // Keys are swallowed while recording, so ⌘W cannot close the tab
            // under the pointer; Escape gives up.
            if event.type == .keyDown {
                if event.keyCode == 53 { stop() }
                return nil
            }
            let held = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if held.isEmpty {
                if !pressed.isEmpty {
                    refusal = Shortcuts.set(pressed, store: store)
                    if refusal != nil { NSSound.beep() }
                    changed()
                }
                stop()
            } else {
                pressed.formUnion(held)
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

/// A key as a cap: a fixed width, so caps in a column line up whatever is
/// printed on them.
private struct KeyCap: View {
    @Environment(Theme.self) private var theme
    let text: String
    let width: CGFloat
    var isDimmed = false
    var isRecording = false

    var body: some View {
        Text(text)
            .font(theme.ui(12.5, weight: .regular))
            .foregroundStyle(isDimmed ? theme.secondaryText : theme.text)
            .frame(width: width, height: 24)
            .background(theme.text.opacity(isRecording ? 0.13 : 0.08), in: .rect(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isRecording ? theme.accent : .clear, lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 0, y: 1)
    }
}
