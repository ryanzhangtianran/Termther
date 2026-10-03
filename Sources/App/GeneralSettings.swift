import AppKit
import Core
import SwiftUI
import VT

/// The General page: where the app's files are, and the keys' modifier.
///
/// What is the app's rather than one feature's lives here. Moving a
/// location points the app somewhere else and moves nothing: the files
/// stay where they were, which the page says.
struct GeneralSettings: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    @State private var shortcutsRevision = 0

    var body: some View {
        @Bindable var theme = theme
        @Bindable var environment = model.shellEnvironment
        Section("Terminal") {
            LabeledContent("Theme") {
                PopUpMenu(Palette.builtIn.map { ($0.name, $0.name) },
                          selection: Binding(
                    get: { theme.palette.name },
                    set: { name in
                        if let palette = Palette.builtIn.first(where: { $0.name == name }) {
                            model.apply(palette)
                        }
                    }))
            }
            // A menu like the theme's, so every choice on the page looks
            // and opens the same way.
            LabeledContent("Font size") {
                PopUpMenu((10...24).map { ("\($0) pt", CGFloat($0)) },
                          selection: $theme.terminalFontSize)
            }
            Multiplier(title: "Line height", value: $theme.terminalLineHeight, range: 0.9...1.8)
            Multiplier(title: "Letter spacing", value: $theme.terminalLetterSpacing, range: 0.9...1.6)
        }
        .onChange(of: theme.terminalFontSize) { model.saveTerminalLayoutSettings() }
        .onChange(of: theme.terminalLineHeight) { model.saveTerminalLayoutSettings() }
        .onChange(of: theme.terminalLetterSpacing) { model.saveTerminalLayoutSettings() }

        Section {
            row("Data", .data)
            row("Keys", .keys)
            row("SSH Config", .sshConfig)
        } header: {
            Text("Locations")
        }

        Section("Keyboard") {
            ModifierRecorder(store: model.store) { shortcutsRevision += 1 }
        }
        Section {
            // Read from the menus themselves, so the list cannot drift from
            // what the keys really do.
            ForEach(Shortcuts.entries()) { entry in
                LabeledContent(entry.title) {
                    Text(entry.keys)
                        .font(theme.ui(13))
                        .foregroundStyle(theme.text)
                }
            }
        }
        // The menus are not observed; this is what redraws.
        .id(shortcutsRevision)

        EnvironmentTable(title: "Local Environment", variables: $environment.variables)
    }

    private func row(_ title: String, _ location: AppPaths.Location) -> some View {
        let url = model.paths[location]
        return LabeledContent(title) {
            HStack(spacing: 8) {
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(theme.ui(13))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose\u{2026}") { choose(location) }
                Button("Show in Finder") { show(url) }
            }
        }
    }

    private func choose(_ location: AppPaths.Location) {
        let isFile = location == .sshConfig
        let panel = NSOpenPanel()
        panel.canChooseFiles = isFile
        panel.canChooseDirectories = !isFile
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = model.paths[location].deletingLastPathComponent()
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setPath(location, to: url) }
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
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    // Apart, so ⌥⌘ reads as two keys rather than one mark.
                    .tracking(isRecording && pressed.isEmpty ? 0 : 4)
                    .foregroundStyle(isRecording && pressed.isEmpty ? theme.secondaryText : theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(theme.text.opacity(isRecording ? 0.12 : 0.07),
                                in: .rect(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isRecording ? theme.accent : .clear, lineWidth: 1.5)
                    }
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
