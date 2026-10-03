import AppKit
import Core
import SwiftUI

/// Brings in what is already written down in `~/.ssh/config`.
///
/// Shown as a list to tick rather than an all-or-nothing button: a config file
/// accumulates entries for machines that no longer exist, and importing those
/// silently would fill the sidebar with dead hosts.
struct ImportList: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    let onFinished: () -> Void

    @State private var entries: [(host: SSHConfig.Host, outcome: Store.ImportOutcome)] = []
    @State private var selected: Set<String> = []
    @State private var hasLoaded = false
    /// Which file the entries came from, when not the one ssh reads: a
    /// batch written out for the purpose can be used instead.
    @State private var chosen: URL?
    private var source: URL { chosen ?? model.paths[.sshConfig] }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty && hasLoaded {
                ContentUnavailableView("No hosts in \(source.lastPathComponent)",
                                       systemImage: "doc.text.magnifyingglass")
            } else {
                List {
                    ForEach(entries, id: \.host.alias) { entry in
                        row(entry)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .task { await load() }
    }

    private func row(_ entry: (host: SSHConfig.Host, outcome: Store.ImportOutcome)) -> some View {
        let isSaved = entry.outcome == .alreadySaved
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { selected.contains(entry.host.alias) },
                set: { on in
                    if on { selected.insert(entry.host.alias) }
                    else { selected.remove(entry.host.alias) }
                }
            )) { EmptyView() }
                .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.host.alias)
                    if isSaved {
                        Text("saved")
                            .font(theme.ui(11))
                            .foregroundStyle(theme.secondaryText)
                    }
                    if entry.host.proxyJump != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.secondaryText)
                    }
                    // Said before importing, because a server with no key
                    // cannot connect and the reason is easy to miss later.
                    if entry.host.effectiveIdentityFile == nil {
                        Text("no key")
                            .font(theme.ui(11))
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle(entry.host))
                    .font(theme.ui(12))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ host: SSHConfig.Host) -> String {
        var text = host.user.isEmpty ? host.address : "\(host.user)@\(host.address)"
        if host.port != 22 { text += ":\(host.port)" }
        if let jump = host.proxyJump { text += "  via \(jump)" }
        return text
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Choose File\u{2026}") { chooseFile() }
                .controlSize(.small)
                .help("Another ssh config file")

            // Worth having at a hundred entries, where ticking one at a time
            // is the slow part.
            Button(selected.count == entries.count ? "None" : "All") {
                selected = selected.count == entries.count
                    ? []
                    : Set(entries.map(\.host.alias))
            }
            .controlSize(.small)
            .disabled(entries.isEmpty)

            Text("\(selected.count) of \(entries.count)")
                .font(theme.ui(12))
                .foregroundStyle(theme.secondaryText)

            Spacer()
            Button("Cancel") { onFinished() }
                .keyboardShortcut(.cancelAction)
            Button("Import") { runImport() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
        }
        .padding(12)
    }

    private func load() async {
        let hosts = SSHConfig.read(at: source)
        entries = (try? await model.store.classify(hosts)) ?? hosts.map { ($0, .new) }
        // Anything already saved starts unticked: the common case is topping
        // up, not re-importing.
        selected = Set(entries.filter { $0.outcome == .new }.map(\.host.alias))
        hasLoaded = true
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL.homeDirectory
        panel.prompt = "Read"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosen = url
        Task { await load() }
    }

    private func runImport() {
        let hosts = entries.map(\.host).filter { selected.contains($0.alias) }
        Task {
            // Jump hosts are linked up after everything is saved, so an entry
            // whose gateway comes later in the file still gets connected.
            await model.importHosts(hosts)
            onFinished()
        }
    }
}
