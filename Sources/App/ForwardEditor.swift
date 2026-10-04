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
        guard Connector.isPort(preset.bindPort) else { return false }
        return preset.direction == .dynamic
            || (!preset.targetHost.isEmpty && Connector.isPort(preset.targetPort))
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
                    }
                }

                Section {
                    Toggle("Start automatically", isOn: $preset.autoStart)
                    Toggle("Reconnect when dropped", isOn: $preset.keepAlive)
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
}
