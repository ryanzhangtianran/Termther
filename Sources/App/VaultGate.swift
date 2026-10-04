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
    @Bindable var model: AppModel

    var body: some View {
        switch model.state {
        case .locked where model.isQuickUnlockEnrolled:
            macUnlock
        case .locked:
            // A view of its own, so a keystroke in the field redraws the
            // field rather than asking the keychain again.
            PasswordUnlock(model: model)
        default:
            // Opening: over in a moment, and a flash of a lock screen for a
            // vault that is about to open by itself would be a false alarm.
            Color.clear
        }
    }

    /// Touch ID, an Apple Watch or the Mac's password, as asked for in Settings.
    private var macUnlock: some View {
        // Asked once: each asking is three round trips to the system.
        let methods = model.quickUnlockMethods
        return VStack(spacing: 22) {
            LockHeading(text: "Termther is locked",
                        detail: methods.map { "Unlock with \($0) to continue." })
            if let error = model.lastError { LockHint(text: error) }
            Button {
                Task { await model.unlockWithMac() }
            } label: {
                Label("Unlock", systemImage: "touchid")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .help(methods.map { "Unlock with \($0)" } ?? "")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A vault from before the key lived in the keychain: its password, once.
private struct PasswordUnlock: View {
    @Environment(Theme.self) private var theme
    let model: AppModel

    @State private var password = ""
    @State private var isWorking = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            LockHeading(text: "Vault password",
                        detail: "Asked once: from then on this Mac's keychain opens it.")
            VStack(spacing: 8) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(theme.hover, in: .rect(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isFocused ? theme.accent : theme.border, lineWidth: 1)
                    }
                if let error = model.lastError { LockHint(text: error) }
            }
            .frame(width: 260)
            Button(action: submit) {
                Text("Unlock").frame(minWidth: 120)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || isWorking)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isFocused = true }
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

/// The lock in a plate of its own, the title, and one line on what opens it.
private struct LockHeading: View {
    @Environment(Theme.self) private var theme
    let text: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 64, height: 64)
                .background(theme.hover, in: .rect(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.border))
                .padding(.bottom, 6)
            Text(text)
                .font(theme.ui(20, weight: .medium))
            if let detail {
                Text(detail)
                    .font(theme.ui(13))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct LockHint: View {
    @Environment(Theme.self) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(theme.ui(12))
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }
}
