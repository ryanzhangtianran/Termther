import SwiftUI

/// The shape every row in the sidebar shares: one inset, one height, one
/// hover and selection fill. A row is a coloured tile and a name, with room
/// around it; what more there is to say is on hover.
struct SidebarRowStyle: ViewModifier {
    /// Every row, header and footer in the sidebar shares this, so nothing in
    /// the column is a pixel off from anything else.
    static let inset: CGFloat = 8
    /// The tile's column and the gap after it. Every row uses these, so
    /// tiles and titles line up down the whole column.
    static let iconColumn: CGFloat = 26
    static let iconGap: CGFloat = 10
    static let titleSize: CGFloat = 14
    static let titleWeight: Font.Weight = .regular
    /// What sits under a row -- a server's tunnels, every session -- one step smaller than
    /// the row itself, so the two levels read apart.
    static let childTitleSize: CGFloat = 12
    /// The corner of every row's fill.
    static let cornerRadius: CGFloat = 12

    @Environment(Theme.self) private var theme
    let isHovering: Bool
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Self.inset)
            .frame(minHeight: 36)
            .background {
                // On the glass: picked, a brighter pane of it with a lit top
                // edge; hovered, a faint wash.
                let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                shape.fill(theme.text.opacity(isSelected ? 0.12 : isHovering ? 0.05 : 0))
                    .overlay(alignment: .top) {
                        if isSelected {
                            shape.strokeBorder(LinearGradient(colors: [theme.text.opacity(0.14), .clear],
                                                              startPoint: .top, endPoint: .center))
                        }
                    }
            }
    }
}

extension View {
    func sidebarRow(hovering: Bool = false, selected: Bool = false) -> some View {
        modifier(SidebarRowStyle(isHovering: hovering, isSelected: selected))
    }
}

/// What an empty section shows: one quiet row that does the obvious thing,
/// in place of a paragraph explaining that there is nothing here.
struct AddRow: View {
    @Environment(Theme.self) private var theme
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SidebarRowStyle.iconGap) {
            Tile(symbol: "plus", size: SidebarRowStyle.iconColumn)
            Text(title)
                .font(theme.ui(SidebarRowStyle.titleSize, weight: SidebarRowStyle.titleWeight))
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.secondaryText)
        .sidebarRow(hovering: isHovering)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onHover { hovering in
            // Eased, so buttons that appear on hover slide in rather than pop.
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
    }
}

extension AnyTransition {
    /// How a row's hover buttons arrive: sliding in from the right as they
    /// fade, rather than appearing in place.
    static var revealFromTrailing: AnyTransition {
        .move(edge: .trailing).combined(with: .opacity)
    }
}

/// Puts text on the clipboard, replacing whatever was there.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
