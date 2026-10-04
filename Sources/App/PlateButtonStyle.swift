import SwiftUI

/// The buttons on Settings' plates: a soft fill rather than the system's
/// bezel, tinted the scheme's blue when it is the thing to press.
struct PlateButtonStyle: ButtonStyle {
    @Environment(Theme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        let color = prominent ? theme.ansi(12) : theme.text
        // Destructive is solid red with white on it: red on a dark red
        // tint was too faint to read as a button at all.
        let fill = destructive ? theme.failing.opacity(0.9)
            : prominent ? color.opacity(0.2) : theme.text.opacity(0.09)
        configuration.label
            .font(theme.ui(11.5, weight: destructive ? .medium : .regular))
            .foregroundStyle(destructive ? .white : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(fill.opacity(configuration.isPressed ? 0.6 : 1),
                        in: .rect(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PlateButtonStyle {
    static var plate: PlateButtonStyle { PlateButtonStyle() }
    static var plateProminent: PlateButtonStyle { PlateButtonStyle(prominent: true) }
    static var plateDestructive: PlateButtonStyle { PlateButtonStyle(destructive: true) }
}
