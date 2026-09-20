import Core
import SwiftUI
import VT

/// Settings, as a tab rather than a window or a panel.
///
/// It sits beside the terminals because that is where there is room to read it,
/// and because closing it is the same gesture as closing anything else.
struct SettingsTab: View {
    @State private var quickUnlock = false
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel
    @State private var credentialCount = 0
    @State private var prunedMessage: String?

    var body: some View {
        @Bindable var theme = theme
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("Colours") {
                    // Shown as swatches rather than a menu of names: the whole
                    // point of a scheme is what it looks like.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                              spacing: 10) {
                        ForEach(Palette.builtIn, id: \.name) { palette in
                            PaletteSwatch(palette: palette,
                                          isSelected: palette.name == theme.palette.name)
                                .onTapGesture { model.apply(palette) }
                        }
                    }
                }

                section("Terminal") {
                    Multiplier(title: "Line height", value: $theme.terminalLineHeight,
                               range: 0.9...1.8)
                    Multiplier(title: "Letter spacing", value: $theme.terminalLetterSpacing,
                               range: 0.9...1.6)

                    Picker("Cursor", selection: $theme.cursorStyle) {
                        ForEach(CursorStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("A program that asks for a particular cursor still gets it -- vim "
                         + "switching shape in insert mode, for instance.")
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }
                .onChange(of: theme.terminalLineHeight) { model.saveTerminalLayoutSettings() }
                .onChange(of: theme.terminalLetterSpacing) { model.saveTerminalLayoutSettings() }
                .onChange(of: theme.cursorStyle) { model.saveTerminalLayoutSettings() }

                section("Credentials") {
                    LabeledContent("Unused keys") {
                        HStack(spacing: 8) {
                            Text(prunedMessage ?? "\(credentialCount) stored")
                                .foregroundStyle(theme.secondaryText)
                            Button("Remove Unused") {
                                Task {
                                    let removed = await model.pruneUnusedCredentials()
                                    prunedMessage = removed == 0
                                        ? "Nothing to remove"
                                        : "Removed \(removed)"
                                    credentialCount = await model.credentialCount()
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("A credential nobody points at still shows up when picking one, "
                         + "which makes it look like a choice.")
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }
                .task { credentialCount = await model.credentialCount() }

                section("Security") {
                    LabeledContent("Vault") {
                        HStack(spacing: 8) {
                            Text("Unlocked").foregroundStyle(theme.secondaryText)
                            Button("Lock Now") { model.lock() }
                                .controlSize(.small)
                        }
                    }
                    Text("Locking closes the server list. Sessions already open keep running.")
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)

                    if let methods = model.quickUnlockMethods {
                        Toggle("Unlock with this Mac", isOn: Binding(
                            get: { quickUnlock },
                            set: { wanted in
                                Task {
                                    if wanted {
                                        quickUnlock = await model.enableQuickUnlock()
                                    } else {
                                        model.disableQuickUnlock()
                                        quickUnlock = false
                                    }
                                }
                            }))
                        Text("\(methods). Keeps the key the password already derived, "
                             + "and asks macOS to confirm the owner before handing it "
                             + "back. The vault password still works, and is still the "
                             + "only thing that can derive the key in the first place.")
                            .font(theme.ui(11))
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text("This Mac has no Touch ID, paired Apple Watch or login "
                             + "password policy available, so the vault password is the "
                             + "only way in.")
                            .font(theme.ui(11))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .task { quickUnlock = model.isQuickUnlockEnrolled }

                section("Proxy") {
                    Toggle("Send local terminals through the proxy", isOn: Binding(
                        get: { model.localProxy.isOn },
                        set: { _ in _ = model.localProxy.toggle() }))
                    Text("New terminals on this Mac start with http_proxy pointed at "
                         + "127.0.0.1:\(String(model.localProxy.port)). \u{2325}\u{2318}P "
                         + "flips it and types the same line into the terminal in front "
                         + "of you \u{2014} a shell already running has the environment it "
                         + "started with, and nothing can reach in and change that.")
                        .font(theme.ui(11))
                        .foregroundStyle(theme.secondaryText)
                }

                section("About") {
                    LabeledContent("Termther") {
                        Text(model.version).foregroundStyle(theme.secondaryText)
                    }
                    LabeledContent("Terminal") {
                        Text("libghostty-vt").foregroundStyle(theme.secondaryText)
                    }
                    LabeledContent("SSH") {
                        Text(model.libssh2Version).foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(theme.ui(10, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            content()
        }
        .font(theme.ui())
    }
}

/// A scheme, shown as what it does rather than what it is called.
private struct PaletteSwatch: View {
    @Environment(Theme.self) private var theme
    let palette: Palette
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                // The eight normal colours, which is what most output uses.
                ForEach(0..<8, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.ansi[index].swiftUI)
                        .frame(height: 14)
                }
            }
            Text(palette.name)
                .font(theme.ui(11))
                .foregroundStyle(palette.foreground.swiftUI)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? theme.accent : theme.border,
                              lineWidth: isSelected ? 2 : 0.5)
        }
        .contentShape(Rectangle())
    }
}

/// A slider for the multipliers that shape the grid.
private struct Multiplier: View {
    @Environment(Theme.self) private var theme
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: 0.05)
                    .frame(width: 170)
                Text(String(format: "%.2f×", value))
                    .font(theme.ui(12))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}
