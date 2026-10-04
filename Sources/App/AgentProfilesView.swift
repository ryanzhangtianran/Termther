import AppKit
import Core
import SwiftUI

/// The Settings section of an agent's page: its profiles, one row each --
/// who it talks to, as a chip -- and the click that puts one in place.
///
/// A profile is made and changed as a form, as CC Switch does it: pick a
/// provider, and its endpoint is filled in; add the key and, if wanted, a
/// model. The files themselves are a menu item away for anything else.
/// What every profile shares -- MCP servers, plugins, permissions, hooks --
/// is not in a profile at all; see `AgentProfile`.
struct AgentProfilesView: View {
    @Environment(Theme.self) private var theme
    let tool: AgentTool
    let agents: Agents

    /// A name being asked for: the current files saved as one, or a rename.
    @State private var naming: Naming?
    @State private var confirmingDeletion: AgentProfile?
    /// The form open: for a new profile, or for one being changed.
    @State private var form: Form?
    /// One of a profile's files, open in the text editor.
    @State private var file: File?

    private var paths: AgentPaths { agents.paths(tool) }

    private struct Naming: Identifiable {
        /// Nil saves the current files under the name.
        let renaming: AgentProfile?
        let id = UUID()
    }

    private struct Form: Identifiable {
        /// Nil for a new profile.
        let profile: AgentProfile?
        let id = UUID()
    }

    private struct File: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private var info: Agents.Info { agents[tool] }

    var body: some View {
        Section {
            ForEach(info.profiles) { profile in
                row(profile)
                .contextMenu {
                    Button("Use") { Task { await agents.applyProfile(profile, for: tool) } }
                    Button("Edit") { form = Form(profile: profile) }
                    ForEach(paths.profileFiles, id: \.self) { name in
                        Button("Edit \(name)") { file = File(url: profile.directory.appending(path: name)) }
                    }
                    Button("Update from Current") { Task { await agents.updateProfile(profile, for: tool) } }
                    Button("Rename") { naming = Naming(renaming: profile) }
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([profile.directory])
                    }
                    Divider()
                    Button("Delete", role: .destructive) { confirmingDeletion = profile }
                }
            }
        } header: {
            HStack {
                Text("Profiles")
                Spacer()
                SwiftUI.Menu {
                    Button("New Profile") { form = Form(profile: nil) }
                    Button("Save Current as Profile") { naming = Naming(renaming: nil) }
                } label: {
                    Tile(symbol: "plus", size: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add Profile")
            }
        }
        .sheet(item: $naming) { naming in
            NameSheet(title: naming.renaming == nil ? "Save as" : "Rename",
                      name: naming.renaming?.name ?? "") { name in
                Task {
                    if let profile = naming.renaming {
                        await agents.renameProfile(profile, to: name, for: tool)
                    } else {
                        await agents.saveProfile(named: name, for: tool)
                    }
                }
            }
        }
        .sheet(item: $form) { form in
            ProfileForm(tool: tool, profile: form.profile,
                        provider: form.profile.flatMap { info.providers[$0.id] } ?? AgentProvider(),
                        taken: Set(info.profiles.map(\.name)).subtracting([form.profile?.name ?? ""]),
                        paths: paths) { name, provider in
                Task {
                    if let profile = form.profile {
                        await agents.setProvider(provider, of: profile, name: name, for: tool)
                    } else {
                        await agents.createProfile(named: name, provider: provider, for: tool)
                    }
                }
            }
        }
        .sheet(item: $file, onDismiss: { Task { await agents.refresh(tool) } }) { file in
            TextFileEditor(url: file.url)
        }
        .alert(item: $confirmingDeletion) { profile in
            Alert(title: Text("Delete \u{201C}\(profile.name)\u{201D}?"),
                  message: Text("Only the saved copy is deleted."),
                  primaryButton: .destructive(Text("Delete")) {
                      Task { await agents.deleteProfile(profile, for: tool) }
                  },
                  secondaryButton: .cancel())
        }
    }

    /// A profile's row: "In Use" on the one in use, a click to make it so,
    /// who it talks to as a chip, and a pencil to open its form.
    private func row(_ profile: AgentProfile) -> some View {
        Button { Task { await agents.applyProfile(profile, for: tool) } } label: {
            HStack(spacing: 10) {
                Text(profile.name).help(info.summaries[profile.id] ?? "")
                // The one in use, said in words after its name rather than
                // with a mark in a column of its own.
                if profile == info.activeProfile {
                    Chip(title: "In Use", color: theme.online)
                }
                Spacer()
                Chip(title: provider(of: profile), color: theme.secondaryText)
                TileButton(symbol: "pencil", help: "Edit") { form = Form(profile: profile) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Official, or the endpoint's host for one of the user's own.
    private func provider(of profile: AgentProfile) -> String {
        let provider = info.providers[profile.id] ?? AgentProvider()
        return provider.baseURL.isEmpty ? "Official" : URL(string: provider.baseURL)?.host ?? "Custom"
    }
}

/// One field asking for a name: a profile's, or a plugin's.
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var prompt = "Work"
    var button = "Save"
    @State var name = ""
    var isValid: (String) -> Bool = { !$0.isEmpty && !$0.contains("/") }
    let done: (String) -> Void

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
            TextField("Name", text: $name, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(button, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid(trimmed))
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func save() {
        guard isValid(trimmed) else { return }
        done(trimmed)
        dismiss()
    }
}

/// A profile as a form, as CC Switch makes one: a row of known providers
/// that fill the endpoint in, then the name, endpoint, key and model.
struct ProfileForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Theme.self) private var theme
    let tool: AgentTool
    /// Nil for a new one.
    let profile: AgentProfile?
    @State var provider: AgentProvider
    /// The other profiles' names, which this one may not take.
    let taken: Set<String>
    /// The tool's files, for who it is signed in as.
    let paths: AgentPaths
    let save: (String, AgentProvider) -> Void

    /// Who the tool is signed in as, once asked; nil inside for no one.
    @State private var account: String??
    /// The tool's own sign-in, running while the browser is out.
    @State private var signingIn: Task<Void, Never>?
    @State private var signInFailure: String?

    @State private var name = ""
    @State private var showsKey = false
    /// Custom rather than the tool's own login: an endpoint of the user's.
    @State private var isCustom = false

    private var isOfficial: Bool { !isCustom }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Why the form cannot be saved yet; nil when it can.
    private var problem: String? {
        if trimmedName.isEmpty { return "Name the profile." }
        if trimmedName.contains("/") || trimmedName.hasPrefix(".") { return "A name cannot contain \u{201C}/\u{201D} or start with a dot." }
        if taken.contains(trimmedName) { return "Another profile is already called \(trimmedName)." }
        let url = provider.baseURL.trimmingCharacters(in: .whitespaces)
        if !isOfficial, !(url.hasPrefix("https://") || url.hasPrefix("http://")) {
            return "The endpoint starts with https://."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Tile(image: tool.logo, size: 26)
                Text(profile == nil ? "New Profile" : profile!.name)
                    .font(theme.ui(14, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Provider").groupTitle(theme).padding(.horizontal, 6)
                    // The known ones, then Custom: one click fills the rest.
                    HStack(spacing: 6) {
                        choice("Official", isOn: isOfficial) {
                            isCustom = false
                            if name.isEmpty, profile == nil { name = "Official" }
                        }
                        choice("Custom", isOn: isCustom) { isCustom = true }
                    }

                    Text("Details").groupTitle(theme).padding(.horizontal, 6).padding(.top, 12)
                    VStack(spacing: 0) {
                        field("Name") {
                            TextField("", text: $name, prompt: Text("Work").foregroundStyle(theme.secondaryText.opacity(0.6)))
                        }
                        Divider().opacity(0.5).padding(.horizontal, 18)
                        if isOfficial {
                            // The tool's own login rather than an endpoint and a key.
                            field("Account") {
                                HStack(spacing: 8) {
                                    if signingIn != nil {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Text(accountText)
                                        .foregroundStyle(signInFailure == nil ? theme.secondaryText : theme.failing)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(signInFailure ?? "")
                                    Spacer(minLength: 8)
                                    if signingIn != nil {
                                        Button("Cancel") { signingIn?.cancel() }
                                            .buttonStyle(.plate)
                                    } else {
                                        Button(account??.isEmpty == false ? "Switch Account" : "Sign In",
                                               action: signIn)
                                            .buttonStyle(.plate)
                                    }
                                }
                            }
                            .task { account = .some(try? await AgentPlugin.account(paths)) }
                            .onDisappear { signingIn?.cancel() }
                        } else {
                            field("Endpoint") {
                                TextField("", text: $provider.baseURL,
                                          prompt: Text("https://").foregroundStyle(theme.secondaryText.opacity(0.6)))
                            }
                            Divider().opacity(0.5).padding(.horizontal, 18)
                            field("API Key") {
                                HStack(spacing: 8) {
                                    Group {
                                        if showsKey {
                                            TextField("", text: $provider.apiKey, prompt: Text("sk-\u{2026}").foregroundStyle(theme.secondaryText.opacity(0.6)))
                                        } else {
                                            SecureField("", text: $provider.apiKey, prompt: Text("sk-\u{2026}").foregroundStyle(theme.secondaryText.opacity(0.6)))
                                        }
                                    }
                                    TileButton(symbol: showsKey ? "eye.slash" : "eye",
                                               help: showsKey ? "Hide" : "Show") { showsKey.toggle() }
                                }
                            }
                        }
                        Divider().opacity(0.5).padding(.horizontal, 18)
                        field("Model") {
                            TextField("", text: $provider.model, prompt: Text("The provider\u{2019}s default").foregroundStyle(theme.secondaryText.opacity(0.6)))
                        }
                    }
                    .plate()
                }
                .padding(20)
            }

            Divider().opacity(0.5)
            HStack(spacing: 8) {
                if let problem {
                    Text(problem)
                        .font(theme.ui(12))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plate)
                    .keyboardShortcut(.cancelAction)
                Button(profile == nil ? "Add" : "Save", action: commit)
                .buttonStyle(.plateProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 470)
        .background(theme.windowBackground)
        .textFieldStyle(.plain)
        .onAppear {
            name = profile?.name ?? ""
            // One of the user's own endpoints opens on Custom, not on a guess.
            isCustom = !provider.baseURL.isEmpty
        }
    }

    private var accountText: String {
        if signingIn != nil { return "Finish signing in in the browser" }
        if let signInFailure { return signInFailure }
        return switch account {
        case .none: "Checking\u{2026}"
        case .some(.none): "Not signed in"
        case .some(.some(let who)): who
        }
    }

    /// The tool's own sign-in, run here rather than in a terminal: it opens
    /// the browser itself, and the row says how it went.
    private func signIn() {
        signInFailure = nil
        signingIn = Task {
            do {
                try await AgentPlugin.login(paths)
            } catch where !Task.isCancelled {
                signInFailure = String(describing: error)
            } catch {}
            account = .some(try? await AgentPlugin.account(paths))
            signingIn = nil
        }
    }

    private func commit() {
        save(trimmedName, isOfficial ? AgentProvider(model: provider.model) : provider)
        dismiss()
    }

    private func choice(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PlateButtonStyle(prominent: isOn))
    }

    /// A label and its field on one row, the field taking the room left.
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .frame(width: 80, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
    }
}
