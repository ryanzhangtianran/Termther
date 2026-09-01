import SwiftUI

/// Stands in front of everything until the vault is open.
///
/// Deliberately the whole window rather than a sheet: until this is answered
/// there is nothing behind it to look at, and a dismissible dialog would imply
/// otherwise.
struct VaultGate: View {
    @Environment(Theme.self) private var theme
    @Bindable var model: AppModel

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @FocusState private var focused: Field?

    private enum Field { case password, confirmation }

    private var isSetup: Bool { model.state == .needsSetup }

    private var canSubmit: Bool {
        guard !password.isEmpty, !isWorking else { return false }
        return isSetup ? password == confirmation && password.count >= 8 : true
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: isSetup ? "lock.rectangle.stack" : "lock")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text(isSetup ? "Create a vault" : "Termther")
                    .font(theme.ui(17, weight: .medium))
                Text(isSetup
                     ? "Your passwords and keys are encrypted with this. It cannot be recovered."
                     : "Enter your vault password to continue.")
                    .font(theme.ui(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            VStack(spacing: 8) {
                field(.password) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: .password)
                        .onSubmit { if isSetup { focused = .confirmation } else { submit() } }

                    // In the field rather than beside it: it is another way of
                    // answering the same question, and a row of its own made
                    // it look like a second decision.
                    if !isSetup, let methods = model.quickUnlockMethods,
                       model.isQuickUnlockEnrolled {
                        Button {
                            Task { await model.unlockWithMac() }
                        } label: {
                            Image(systemName: "touchid")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Unlock with \(methods)")
                    }
                }

                if isSetup {
                    field(.confirmation) {
                        SecureField("Repeat password", text: $confirmation)
                            .textFieldStyle(.plain)
                            .focused($focused, equals: .confirmation)
                            .onSubmit(submit)
                    }

                    if !password.isEmpty && password.count < 8 {
                        hint("At least 8 characters.")
                    } else if !confirmation.isEmpty && password != confirmation {
                        hint("The two do not match.")
                    }
                }

                if let error = model.lastError {
                    hint(error, isError: true)
                }
            }
            .frame(width: 280)

            // Neutral rather than tinted: a block of accent colour is the
            // loudest thing in the window for a decision nobody is weighing.
            Button(isSetup ? "Create Vault" : "Unlock", action: submit)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .fixedSize()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = .password }
    }

    /// One field, drawn by hand so something can sit inside it.
    ///
    /// `.roundedBorder` has no room for an accessory, and putting the button
    /// outside made a single question look like two.
    private func field<Content: View>(_ id: Field,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(theme.hover)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused == id ? theme.accent : theme.border, lineWidth: 1)
            }
    }

    private func hint(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(theme.ui(11))
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        Task {
            if isSetup {
                await model.createVault(password: password)
            } else {
                await model.unlock(password: password)
            }
            isWorking = false
            password = ""
            confirmation = ""
        }
    }
}
