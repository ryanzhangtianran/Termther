import Core
import EC
import SwiftUI

/// Adds or edits one EasyConnect gateway.
struct VPNEditor: View {
    @Environment(Theme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State private var profile: VPNProfile
    @State private var password = ""
    @State private var totp = ""
    @State private var showsUnderlay = false
    @State private var isWorking = false

    init(model: AppModel, profile: VPNProfile) {
        self.model = model
        _profile = State(initialValue: profile)
    }

    private var isNew: Bool { profile.id == nil }

    private var canSave: Bool {
        !profile.gateway.isEmpty && !profile.username.isEmpty && !isWorking
            && (!isNew || !password.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $profile.name, prompt: Text(profile.gateway))
                    TextField("Gateway", text: $profile.gateway,
                              prompt: Text("connect.example.edu.cn:443"))
                    TextField("Username", text: $profile.username)
                    SecureField("Password", text: $password,
                                prompt: Text(isNew ? "Required" : "Leave blank to keep"))
                    SecureField("TOTP secret", text: $totp,
                                prompt: Text("Optional, base32"))
                    Text("The password is sealed in the same vault as everything "
                         + "else and only opened at the moment you connect.")
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }

                Section {
                    HStack(spacing: 8) {
                        Button("Test Gateway") {
                            Task { await model.vpn.probe(gateway: profile.gateway) }
                        }
                        .controlSize(.small)
                        .disabled(profile.gateway.isEmpty)

                        if let probe = model.vpn.lastProbe {
                            Text(probe)
                                .font(theme.ui(11))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    Text("Asks the gateway what it is, without sending a password. "
                         + "aTrust answers here too, and it speaks a different protocol.")
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }

                Section {
                    DisclosureGroup(isExpanded: $showsUnderlay) {
                        TextField("Interface", text: Binding(
                            get: { profile.interfaceName ?? "" },
                            set: { profile.interfaceName = $0.isEmpty ? nil : $0 }),
                                  prompt: Text("en0"))
                        TextField("DNS server", text: Binding(
                            get: { profile.dnsServer ?? "" },
                            set: { profile.dnsServer = $0.isEmpty ? nil : $0 }),
                                  prompt: Text("223.5.5.5"))
                        // These exist because of local TUN proxies: Surge,
                        // Clash and sing-box take the default route and answer
                        // DNS with 198.18.0.0/15, so without pinning both the
                        // engine dials the proxy instead of the gateway and
                        // fails during the handshake -- which reads as the
                        // gateway being down.
                        Text("Only needed when a local proxy has taken the default "
                             + "route. Pins the engine's own socket to one interface "
                             + "and resolver.")
                            .font(theme.ui(11))
                            .foregroundStyle(theme.secondaryText)
                    } label: {
                        Text("Underlay")
                            .font(theme.ui(12))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 460, height: 470)
    }

    /// Says what the engine will actually use, so an empty field does not read
    /// as "nothing".
    private var underlayNote: String {
        let found = EasyConnect.Underlay(interfaceName: profile.interfaceName,
                                         dnsServer: profile.dnsServer).resolved()
        let interface = found.interfaceName ?? "none found"
        let dns = found.dnsServer ?? "none found"
        return "Left blank these are worked out from the machine: right now "
            + "\(interface) and \(dns). They travel together \u{2014} the engine "
            + "binds to a physical interface either way, so a resolver from a "
            + "local proxy would hand it an address that only exists inside "
            + "that proxy."
    }

    private func save() {
        isWorking = true
        Task {
            var profile = self.profile
            if profile.name.isEmpty { profile.name = profile.gateway }

            if !password.isEmpty || !totp.isEmpty {
                // Both halves are re-sealed together, so whichever field was
                // left blank keeps what it had: typing a new password must not
                // quietly drop the second factor.
                var secret: String? = password.isEmpty ? nil : password
                if secret == nil {
                    secret = try? await model.vault.openText(
                        profile.sealed, context: VPNProfile.passwordContext)
                }
                var seed: String? = totp.isEmpty ? nil : totp
                if seed == nil, let sealed = profile.totpSealed {
                    seed = try? await model.vault.openText(
                        sealed, context: VPNProfile.totpContext)
                }

                if let secret, let sealed = await model.vpn.seal(password: secret, totp: seed) {
                    profile.secret = sealed.0.ciphertext
                    profile.secretNonce = sealed.0.nonce
                    profile.totpSecret = sealed.1?.ciphertext
                    profile.totpSecretNonce = sealed.1?.nonce
                }
            }

            await model.vpn.save(profile)
            isWorking = false
            dismiss()
        }
    }
}
