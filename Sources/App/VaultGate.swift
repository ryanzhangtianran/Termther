import SwiftUI

/// Stands in front of everything until the vault is open.
///
/// Normally never seen: the vault's key is in the keychain and it opens by
/// itself. It shows when the Mac's confirmation has been asked for in
/// Settings, and -- once -- for a vault made with a password before the key
/// was kept there.
///
/// Deliberately the whole window rather than a sheet: until this is answered
/// there is nothing behind it to look at, and a dismissible dialog would imply
/// otherwise.
struct VaultGate: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel

    @State private var password = ""
    @State private var isWorking = false
    @FocusState private var isFocused: Bool

    var body: some View {
        switch model.state {
        case .locked where model.isQuickUnlockEnrolled:
            macUnlock
        case .locked:
            passwordUnlock
        default:
            // Opening: over in a moment, and a flash of a lock screen for a
            // vault that is about to open by itself would be a false alarm.
            Color.clear
        }
    }

    /// Touch ID, an Apple Watch or the Mac's password, as asked for in Settings.
    private var macUnlock: some View {
        VStack(spacing: 20) {
            heading("Locked")
            if let error = model.lastError { hint(error) }
            Button {
                Task { await model.unlockWithMac() }
            } label: {
                Label("Unlock", systemImage: "touchid")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .help(model.quickUnlockMethods.map { "Unlock with \($0)" } ?? "")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A vault from before the key lived in the keychain: its password, once.
    private var passwordUnlock: some View {
        VStack(spacing: 20) {
            heading("Vault password")
            VStack(spacing: 8) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(theme.hover)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isFocused ? theme.accent : theme.border, lineWidth: 1)
                    }
                if let error = model.lastError { hint(error) }
            }
            .frame(width: 280)
            Button("Unlock", action: submit)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || isWorking)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isFocused = true }
    }

    private func heading(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .font(theme.ui(18, weight: .medium))
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(theme.ui(12))
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }

    private func submit() {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            await model.unlock(password: password)
            // From now on the keychain opens it; this password is not asked again.
            if model.state == .unlocked { await model.rememberKey() }
            isWorking = false
            password = ""
        }
    }
}
