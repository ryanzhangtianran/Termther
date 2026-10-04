import SwiftUI

/// A line symbol in its square: how servers and Settings' pages are marked,
/// in grey, so the green of an answering server or the red of a delete is
/// what catches the eye. A status light can sit on its corner.
struct Tile: View {
    @Environment(Theme.self) private var theme
    var symbol: String?
    /// Drawn instead of `symbol`: an agent's own mark.
    var image: Image?
    /// Nil for grey; a colour only for state -- a switch that is on, a delete.
    var color: Color?
    var size: CGFloat = 24
    /// Green, red or yellow on the top-right corner; nil for none.
    var light: Color?

    var body: some View {
        (image ?? Image(systemName: symbol ?? "square"))
            .resizable()
            .scaledToFit()
            .fontWeight(.regular)
            .foregroundStyle(color ?? theme.secondaryText)
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let light {
                    Circle()
                        .fill(light)
                        .frame(width: size * 0.36, height: size * 0.36)
                        // Ringed in the window's colour, so it sits on the
                        // tile rather than in it.
                        .padding(size * 0.08)
                        .background(Circle().fill(theme.palette.background.swiftUI))
                        .offset(x: size * 0.18, y: -size * 0.18)
                }
            }
    }
}
