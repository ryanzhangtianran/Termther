import Core
import SwiftUI

/// The expanded panel beside the activity bar.
///
/// The header carries the section's name on the left and its search on the
/// right, so the panel's own chrome occupies one row instead of two and the
/// list starts as high as it can.
struct SidePanel: View {
    @Environment(Theme.self) private var theme
    let activity: Activity
    @Bindable var model: AppModel
    /// Driven by the window's own search field, above the cards.
    let search: String
    let open: (Server) -> Void

    /// Every row, the header and the footer share this, so nothing in the
    /// column is a pixel off from anything else.
    static let inset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch activity {
            case .servers:  ServerList(model: model, search: search, open: open)
            case .proxy:    ProxyPanel(model: model)
            case .vpn:      VPNPanel(model: model)
            }
        }
    }

    private var header: some View {
        Text(activity.title.uppercased())
            .font(theme.ui(10, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .frame(height: 26, alignment: .center)
            .padding(.horizontal, Self.inset)
    }
}

/// A compact search box.
///
/// Not `.searchable`: that puts a full-width field on its own row above the
/// list, which in a 240pt column costs more space than it earns.
struct SearchField: View {
    @Environment(Theme.self) private var theme
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
            TextField("", text: $text, prompt: Text("Search").foregroundStyle(theme.secondaryText))
                .textFieldStyle(.plain)
                .font(theme.ui(11))
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        // Grows when it is being used, so an idle search takes only the room
        // it needs.
        .frame(width: isFocused || !text.isEmpty ? 220 : 130)
        .background(theme.hover)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isFocused ? theme.accent : .clear, lineWidth: 1)
        }
        .animation(.snappy(duration: 0.15), value: isFocused)
    }
}
