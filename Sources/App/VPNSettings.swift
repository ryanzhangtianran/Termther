import Core
import VPN
import SwiftUI

/// The one EasyConnect gateway, as sections of the Settings form.
///
/// In Settings rather than a sheet: there is only ever one, so it is a setting
/// of the app like any other. Saved by hand, unlike the rest of Settings,
/// because the password is sealed into the vault on the way.
struct VPNSettings: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    @State private var profile: VPNProfile
    @State private var password = ""
    @State private var totp = ""
    @State private var showsUnderlay = false
    @State private var showsRoutes = false
    @State private var isWorking = false

    init(model: AppModel) {
        self.model = model
        _profile = State(initialValue: model.vpn.profile ?? Self.blank)
    }

    private static let blank = VPNProfile(
        name: "", gateway: "", username: "",
        sealed: .init(ciphertext: Data(), nonce: Data()))

    private var isNew: Bool { profile.id == nil }

    private var isDirty: Bool {
        profile != (model.vpn.profile ?? Self.blank) || !password.isEmpty || !totp.isEmpty
    }

    private var canSave: Bool {
        isDirty && !profile.gateway.isEmpty && !profile.username.isEmpty && !isWorking
            && (!isNew || !password.isEmpty)
    }

    var body: some View {
        Section("Gateway") {
            if let saved = model.vpn.profile {
                LabeledContent("Connection") {
                    HStack(spacing: 10) {
                        Text(status)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                            .help(status)
                        Toggle("", isOn: Binding(
                            get: { model.vpn.state.isOn },
                            set: { wanted in
                                Task {
                                    if wanted { await model.vpn.connect(saved) }
                                    else { await model.vpn.disconnect() }
                                }
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch).controlSize(.mini)
                            .disabled(model.vpn.state == .connecting)
                    }
                }
            }
            FieldRow(title: "Name", text: $profile.name, prompt: profile.gateway)
            FieldRow(title: "Gateway", text: $profile.gateway)
            FieldRow(title: "Username", text: $profile.username)
            // A saved one shows as asterisks; typing replaces it, and leaving
            // it empty keeps it.
            FieldRow(title: "Password", text: $password,
                     prompt: isNew ? nil : "********", isSecure: true)
            // The seed behind an authenticator app's six-digit codes (TOTP), so
            // a gateway that asks for one gets it without reaching for a phone.
            FieldRow(title: "TOTP secret", text: $totp,
                     prompt: profile.totpSealed == nil ? nil : "********",
                     isSecure: true)
            HStack(spacing: 8) {
                // Asks the gateway what it is, without sending a password --
                // an aTrust gateway answers too, and speaks something else.
                Button("Test") {
                    Task { await model.vpn.probe(gateway: profile.gateway) }
                }
                .disabled(profile.gateway.isEmpty)
                // Just the verdict; the gateway's own words are on hover, for
                // when it failed and the reason matters.
                if let probe = model.vpn.lastProbe {
                    HStack(spacing: 4) {
                        switch probe.succeeded {
                        case nil:
                            ProgressView().controlSize(.small)
                            Text("Checking\u{2026}")
                        case true?:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Success")
                        case false?:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text("Failed")
                        }
                    }
                    .foregroundStyle(theme.secondaryText)
                    .help(probe.detail)
                }
                Spacer(minLength: 8)
                Button(isNew ? "Add" : "Save", action: save)
                    .disabled(!canSave)
            }
        }
        // Picks up the saved gateway once the vault has loaded it.
        .task(id: model.vpn.profile?.id) {
            if !isDirty || isNew, let saved = model.vpn.profile { profile = saved }
        }

        // Which servers are reached through it; the same switch as the
        // server's context menu and editor.
        if !model.servers.isEmpty {
            Section("Connections") {
                ForEach(model.servers) { server in
                    Toggle(isOn: Binding(
                        get: { server.routesThroughVPN },
                        set: { wanted in
                            Task { await model.setRoutesThroughVPN(wanted, for: server) }
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName)
                            Text(server.host)
                                .font(theme.ui(12))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                }
            }
        }

        // Folded by its header rather than a DisclosureGroup inside a
        // row: that crammed its fields under the label instead of laying
        // them out as rows of the form.
        Section {
            if showsUnderlay {
            FieldRow(title: "Interface", text: Binding(
                get: { profile.interfaceName ?? "" },
                set: { profile.interfaceName = $0.isEmpty ? nil : $0 }),
                     prompt: "en0")
            FieldRow(title: "DNS server", text: Binding(
                get: { profile.dnsServer ?? "" },
                set: { profile.dnsServer = $0.isEmpty ? nil : $0 }),
                     prompt: "223.5.5.5")
            // These exist because of local TUN proxies: Surge,
            // Clash and sing-box take the default route and answer
            // DNS with 198.18.0.0/15, so without pinning both the
            // engine dials the proxy instead of the gateway and
            // fails during the handshake -- which reads as the
            // gateway being down.
            }
        } header: {
            FoldHeader(title: "Advanced", isExpanded: $showsUnderlay)
        }

        // What the gateway routes, once connected. Worth having: it
        // drops traffic to anything outside this list rather than
        // refusing it, so a missing host looks exactly like a hang.
        if model.vpn.state.isOn, let routing = model.vpn.routing, !routing.isEmpty {
            Section {
                if showsRoutes {
                ForEach(routing.ip) { range in
                    LabeledContent {
                        Text("\(range.ports) \u{00B7} \(range.protocolName)")
                    } label: {
                        Text(range.addresses)
                            .font(theme.ui(13))
                            .textSelection(.enabled)
                    }
                }
                if !routing.dns.isEmpty {
                    LabeledContent("DNS", value: routing.dns.joined(separator: ", "))
                }
                if !routing.domains.isEmpty {
                    LabeledContent("Domains") {
                        Text(routing.domains.joined(separator: ", "))
                            .font(theme.ui(13))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
                }
            } header: {
                FoldHeader(title: "Routes (\(routing.ip.count))", isExpanded: $showsRoutes)
            }
        }
    }

    private var status: String {
        switch model.vpn.state {
        case .off:                  "Not connected"
        case .connecting:           "Connecting\u{2026}"
        case .on(let address):      "Connected as \(address)"
        case .failed(let reason):   reason
        }
    }

    private var statusColor: Color {
        switch model.vpn.state {
        case .on:     .green
        case .failed: .orange
        default:      theme.secondaryText
        }
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

            if let saved = await model.vpn.save(profile) { self.profile = saved }
            password = ""
            totp = ""
            isWorking = false
        }
    }
}
