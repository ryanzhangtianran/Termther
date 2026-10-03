import Core
import Foundation
import Observation
import SwiftUI

/// What a new local terminal starts with, beyond what the app inherited: the
/// variables set in Settings. A server's terminals have their own list, in
/// its connection settings.
///
/// The one writer of `LocalShell.newShellEnvironment`.
@MainActor
@Observable
final class ShellEnvironment {
    typealias Variable = EnvironmentVariable

    /// In the order they were added, which is the order they are shown.
    var variables: [Variable] = [] {
        didSet {
            guard variables != oldValue else { return }
            apply()
            save()
        }
    }

    /// Everything a new terminal gets.
    var current: [String: String] {
        var result: [String: String] = [:]
        for variable in variables where variable.isValid { result[variable.name] = variable.value }
        return result
    }

    private let store: Store
    private static let settingKey = "shellEnvironment"

    init(store: Store) {
        self.store = store
    }

    func restore() async {
        guard let json = try? await store.setting(Self.settingKey),
              let saved = try? JSONDecoder().decode([Variable].self, from: Data(json.utf8))
        else { return }
        variables = saved
    }

    private func apply() {
        LocalShell.newShellEnvironment = current.merging(Self.zshIntegration) { own, _ in own }
    }

    // MARK: - zsh integration

    /// Set once the integration is installed; until then new shells start
    /// plainly. Only the app installs it -- never a test.
    private static var zshIntegrationDirectory: URL?

    /// What points a new zsh at the integration: ZDOTDIR to ours, with the
    /// user's own kept for the script to put back.
    private static var zshIntegration: [String: String] {
        guard let directory = zshIntegrationDirectory else { return [:] }
        var variables = ["ZDOTDIR": directory.path]
        if let own = ProcessInfo.processInfo.environment["ZDOTDIR"] {
            variables["TERMTHER_ZDOTDIR"] = own
        }
        return variables
    }

    /// Writes the zsh integration where new shells will find it.
    ///
    /// It marks where each prompt starts and ends with OSC 133, as Ghostty's
    /// integration does, which is how the emulator finds the prompt to put
    /// back in place when the window is resized. And before each command it
    /// picks up a change of proxy left for it -- see `request(_:forShell:)`.
    func installZshIntegration() {
        let integration = URL.applicationSupportDirectory
            .appending(path: "Termther/shell-integration", directoryHint: .isDirectory)
        let directory = integration.appending(path: "zsh", directoryHint: .isDirectory)
        let requests = integration.appending(path: "requests", directoryHint: .isDirectory)
        do {
            // Left over from shells that are gone; a pid comes round again.
            try? FileManager.default.removeItem(at: requests)
            for folder in [directory, requests] {
                try FileManager.default.createDirectory(at: folder,
                                                        withIntermediateDirectories: true)
            }
            try Self.zshenv(requests: requests.path)
                .write(to: directory.appending(path: ".zshenv"), atomically: true, encoding: .utf8)
            Self.zshIntegrationDirectory = directory
            Self.requestDirectory = requests
            apply()
        } catch {
            // New shells start without the marks; nothing else depends on them.
        }
    }

    /// Where a running zsh picks up lines to run, one file per shell.
    private static var requestDirectory: URL?

    /// Has a running zsh run `line` straight away, unseen, and redraw its
    /// prompt -- the way to change the environment of a shell that has
    /// already started, short of typing into it. False when there is no zsh
    /// integration to pick it up, and the caller has to type it after all.
    static func request(_ line: String, forShell pid: pid_t) -> Bool {
        guard let directory = requestDirectory,
              ProcessInfo.processInfo.environment["SHELL"]?.hasSuffix("/zsh") ?? true
        else { return false }
        let file = directory.appending(path: String(pid))
        guard (try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)) != nil
        else { return false }
        // The integration's cue to take it now and redraw the prompt.
        // SIGWINCH because anything else that gets it just redraws too:
        // an unexpected SIGUSR1 would end the process.
        kill(pid, SIGWINCH)
        return true
    }

    /// Drops what a shell never picked up, once it is gone.
    static func forget(shell pid: pid_t) {
        guard let directory = requestDirectory else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: String(pid)))
    }

    private static func zshenv(requests: String) -> String {
        zshenvTemplate.replacingOccurrences(
            of: "@REQUESTS@", with: "'" + requests.replacingOccurrences(of: "'", with: "'\\''") + "'")
    }

    private static let zshenvTemplate = #"""
    # Termther shell integration for zsh. Termther points ZDOTDIR here so this
    # runs first; it puts the user's own ZDOTDIR back at once, so every other
    # startup file -- .zprofile, .zshrc -- is theirs, read as usual.
    if [[ -n "${TERMTHER_ZDOTDIR+x}" ]]; then
      ZDOTDIR="$TERMTHER_ZDOTDIR"
      unset TERMTHER_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"

    # Interactive shells: mark each prompt (OSC 133), so a resized window has
    # the prompt redrawn in place rather than stacked below stale copies.
    if [[ -o interactive ]]; then
      autoload -Uz add-zsh-hook add-zle-hook-widget
      typeset -gi _termther_ran=0
      _termther_precmd() {
        local code=$?
        (( _termther_ran )) && builtin print -n "\e]133;D;${code}\a"
        _termther_ran=0
        builtin print -n "\e]133;A\a"
      }
      # A change Termther left for this shell -- the proxy switched on its
      # row -- run here, then removed. Termther sends SIGWINCH once it is
      # written, and the prompt is drawn again so it shows the change at
      # once; before each command is the fallback if that was missed.
      _termther_pickup() {
        local request=@REQUESTS@/$$
        [[ -r $request ]] || return 1
        builtin source $request
        command rm -f -- $request
      }
      # Zero whatever happened: a trap that returns non-zero leaves zsh
      # behaving as if interrupted, and this one runs on every resize too.
      TRAPWINCH() { _termther_pickup && zle && zle reset-prompt; return 0 }
      _termther_preexec() {
        _termther_ran=1
        _termther_pickup
        builtin print -n "\e]133;C\a"
      }
      _termther_line_init() { builtin print -n "\e]133;B\a" }
      add-zsh-hook precmd _termther_precmd
      add-zsh-hook preexec _termther_preexec
      add-zle-hook-widget line-init _termther_line_init
    fi
    """#

    private func save() {
        guard let data = try? JSONEncoder().encode(variables) else { return }
        let json = String(decoding: data, as: UTF8.self)
        Task { try? await store.setSetting(Self.settingKey, to: json) }
    }
}

/// Variables a terminal starts with, as a two-column table: Settings uses it
/// for local terminals, a server's editor for that server's.
struct EnvironmentTable: View {
    @Environment(Theme.self) private var theme
    let title: String
    @Binding var variables: [EnvironmentVariable]

    private let nameWidth: CGFloat = 180

    var body: some View {
        Section(title) {
            HStack(spacing: 8) {
                Text("Name").frame(width: nameWidth, alignment: .leading)
                Text("Value")
                Spacer()
            }
            .font(theme.ui(12))
            .foregroundStyle(theme.secondaryText)

            ForEach($variables) { $variable in
                HStack(spacing: 8) {
                    TextField("", text: $variable.name, prompt: Text("NAME"))
                        .labelsHidden()
                        // Red while it is not a name a shell would take; such a
                        // row is kept but not applied.
                        .foregroundStyle(variable.isValid || variable.name.isEmpty
                                         ? theme.text : .red)
                        .frame(width: nameWidth)
                    TextField("", text: $variable.value, prompt: Text("value"))
                        .labelsHidden()
                    Button {
                        variables.removeAll { $0.id == variable.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .help("Remove")
                }
                .font(theme.ui(13))
                .textFieldStyle(.plain)
            }

            Button {
                variables.append(.init(name: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
        }
    }
}
