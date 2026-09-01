import SwiftUI

/// A section the side panel can show.
///
/// Settings is deliberately not one of these: it is a place you go and read,
/// not a list you keep beside your work, so it opens as a tab like a document
/// rather than squeezing into a 240pt column.
enum Activity: String, CaseIterable, Identifiable {
    case servers
    case proxy
    case vpn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .servers: "Servers"
        case .proxy: "Proxy"
        case .vpn: "VPN"
        }
    }

    var icon: String {
        switch self {
        case .servers: "server.rack"
        case .proxy: "arrow.uturn.left"
        case .vpn: "lock.shield"
        }
    }
}

/// The narrow strip of icons on the far left.
///
/// Clicking the selected one collapses the panel, which is the behaviour
/// everyone already expects from this shape of interface.
struct ActivityBar: View {
    @Binding var selection: Activity?
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Activity.allCases) { activity in
                ActivityButton(
                    icon: activity.icon, title: activity.title,
                    isSelected: selection == activity,
                    action: { selection = selection == activity ? nil : activity })
            }

            // Anything below the spacer is about the app rather than the work.
            Spacer(minLength: 8)

            ActivityButton(icon: "gearshape", title: "Settings",
                           isSelected: false, action: openSettings)
        }
        .padding(.vertical, 8)
        .frame(width: 44)
    }
}

private struct ActivityButton: View {
    @Environment(Theme.self) private var theme
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var background: Color {
        if isSelected { theme.selection }
        else if isHovering { theme.hover }
        else { .clear }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 32, height: 30)
                .foregroundStyle(isSelected ? theme.text : theme.secondaryText)
                .background { RoundedRectangle(cornerRadius: 7).fill(background) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
    }
}
