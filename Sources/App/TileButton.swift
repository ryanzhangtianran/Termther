import SwiftUI

/// An icon that does something, drawn as a `Tile` so a row's buttons read
/// as one family with its icons: grey unless it is given a colour, as a
/// switch that is on is, and brightened on a flat square under the pointer.
struct TileButton: View {
    @Environment(Theme.self) private var theme
    var symbol: String?
    var image: Image?
    var color: Color?
    var size: CGFloat = 22
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // Grey until it is given a colour or the pointer: a row of
            // buttons in ink would outshine the name beside them.
            Tile(symbol: symbol, image: image, color: color ?? (isHovering ? theme.text : theme.secondaryText),
                 size: size)
                .background(theme.text.opacity(isHovering ? 0.08 : 0),
                            in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}
