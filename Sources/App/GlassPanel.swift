import SwiftUI

/// A rounded pane of frosted light: brighter at the top than the bottom,
/// a lit top edge, a hairline and a soft shadow under it. Drawn rather than
/// the system's glass, which over the terminal's flat dark reads as a plain
/// grey slab -- there is nothing behind it to refract.
struct GlassPanel: View {
    @Environment(Theme.self) private var theme
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [theme.text.opacity(0.10), theme.text.opacity(0.055)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [theme.text.opacity(0.18), theme.text.opacity(0.05)],
                                                       startPoint: .top, endPoint: .bottom)))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}
