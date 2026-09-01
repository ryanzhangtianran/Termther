import Core
import SwiftUI

/// Adds or edits one server's route back through this Mac.
///
/// Saved and edited like a server rather than switched on with a default: the
/// port on the server is a real choice (it has to be free there, and it is the
/// one `http_proxy` will name), and so is whether the tunnel is supervised.
struct ProxyEditor: View {
    @Environment(Theme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var preset: PortForwardPreset

    init(model: AppModel, preset: PortForwardPreset) {
        self.model = model
        _preset = State(initialValue: preset)
    }

    private var isNew: Bool { preset.id == nil }

    /// The servers this may point at: the free ones, plus whichever it already
    /// uses. One tunnel per server, because a second would bind the same port
    /// on the same machine and be refused.
    private var candidates: [Server] {
        model.servers.filter { server in
            guard let id = server.id else { return false }
            return id == preset.serverId || model.forwards.proxyBack(for: id) == nil
        }
    }

    private var canSave: Bool { preset.serverId != 0 && preset.bindPort > 0 }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Server", selection: $preset.serverId) {
                        if preset.serverId == 0 {
                            Text("Choose\u{2026}").tag(Int64(0))
                        }
                        ForEach(candidates) { server in
                            Text(server.name.isEmpty ? server.host : server.name)
                                .tag(server.id ?? 0)
                        }
                    }
                    TextField("Port on the server", value: $preset.bindPort,
                              format: .number.grouping(.never))
                    Text(explanation)
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }

                Section {
                    Toggle("Start it automatically", isOn: $preset.autoStart)
                    Toggle("Put it back when it drops", isOn: $preset.keepAlive)
                    Text("Both matter more here than for an ordinary tunnel: the "
                         + "server\u{2019}s terminals are pointed at this port, so "
                         + "while it is down their commands reach nothing at all.")
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Remove", role: .destructive) {
                        Task {
                            await model.forwards.delete(preset)
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    Task {
                        await model.forwards.saveProxy(preset)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 430, height: 380)
    }

    /// Written out in full because the two ports live on different machines,
    /// and that is the thing people get backwards.
    private var explanation: String {
        let there = String(preset.bindPort)
        let here = String(model.forwards.proxyLocalPort)
        return "The server listens on its own 127.0.0.1:\(there). Whatever connects "
            + "there comes down the SSH connection and out at 127.0.0.1:\(here) on "
            + "this Mac. New terminals on the server get http_proxy pointed at "
            + "\(there), so curl, git and the rest go out through it."
    }
}
