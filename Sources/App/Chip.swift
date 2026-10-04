import SwiftUI

/// A short state in a capsule of its own colour: "Failed", "VPN", "Online".
struct Chip: View {
    @Environment(Theme.self) private var theme
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(theme.ui(10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.17), in: Capsule())
            .fixedSize()
    }
}
