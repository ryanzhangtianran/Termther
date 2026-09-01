import Core
import SwiftUI

/// Adds or edits one tunnel on a server.
///
/// Opened from the server that carries it, so there is no server to pick: a
/// forward without one is meaningless, and the editor that owns the server is
/// the place the question already has an answer.
///
/// Only the two outward directions are offered. The reverse direction exists
/// -- it is what carries a server's traffic back here -- but it is the Proxy
/// panel's whole subject, and offering it here as a bare tunnel would be a
/// second, worse way to set up the same thing.
struct ForwardEditor: View {
    @Environment(Theme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var preset: PortForwardPreset
    /// Handed back rather than saved: a forward belongs to a server, and the
    /// server may not have been saved yet.
    let onSave: (PortForwardPreset) -> Void

    init(preset: PortForwardPreset, onSave: @escaping (PortForwardPreset) -> Void) {
        // The picker has no reverse option, and a selection it cannot show
        // would leave it blank.
        var preset = preset
        if preset.direction == .remote { preset.direction = .local }
        _preset = State(initialValue: preset)
        self.onSave = onSave
    }

    private var isNew: Bool { preset.id == nil }

    private var canSave: Bool {
        guard preset.bindPort > 0 else { return false }
        return preset.direction == .dynamic
            || (!preset.targetHost.isEmpty && preset.targetPort > 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Kind", selection: $preset.direction) {
                        Text("Local").tag(PortForwardPreset.Direction.local)
                        Text("SOCKS5").tag(PortForwardPreset.Direction.dynamic)
                    }
                    .pickerStyle(.segmented)
                    Text(explanation)
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }

                Section("Listen") {
                    TextField("Address", text: $preset.bindHost, prompt: Text("127.0.0.1"))
                    TextField("Port", value: $preset.bindPort,
                              format: .number.grouping(.never))
                }

                if preset.direction == .local {
                    Section("Connect to") {
                        TextField("Host", text: $preset.targetHost,
                                  prompt: Text("127.0.0.1"))
                        TextField("Port", value: $preset.targetPort,
                                  format: .number.grouping(.never))
                        // Resolved on the server, not here: "localhost" means
                        // the server itself, which is the point.
                        Text("Names are resolved by the server, so localhost "
                             + "means the server itself.")
                            .font(theme.ui(11))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Section {
                    Toggle("Start it automatically", isOn: $preset.autoStart)
                    Toggle("Put it back when it drops", isOn: $preset.keepAlive)
                    Text("Brought up when the vault is unlocked, on its own "
                         + "connection \u{2014} no terminal needed. A dropped "
                         + "tunnel is retried with a widening gap, up to half "
                         + "a minute.")
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var preset = preset
                    // A blank address means the usual one rather than every
                    // interface: a forward reachable from the network is a
                    // decision, not a typo.
                    if preset.bindHost.isEmpty { preset.bindHost = "127.0.0.1" }
                    if preset.direction == .dynamic {
                        preset.targetHost = ""
                        preset.targetPort = 0
                    }
                    // Owned by the Proxy panel alone; a forward made here is a
                    // plain tunnel however it is pointed.
                    preset.exportsEnvironment = false
                    onSave(preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 430, height: 470)
    }

    private var explanation: String {
        switch preset.direction {
        case .local:
            "A port here that arrives somewhere the server can reach. ssh -L."
        case .dynamic:
            "A SOCKS5 proxy here; every connection is dialled by the server. ssh -D."
        case .remote:
            // Not offered here; the Proxy panel makes these.
            "A port on the server that arrives here. ssh -R."
        }
    }
}
