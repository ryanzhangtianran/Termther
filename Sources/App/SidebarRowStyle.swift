import SwiftUI

/// The shape every row in the sidebar shares: one inset, one minimum height,
/// one hover and selection fill. Type follows the same rule -- 12pt for what a
/// row is, 11pt for everything said about it.
struct SidebarRowStyle: ViewModifier {
    /// Every row, header and footer in the sidebar shares this, so nothing in
    /// the column is a pixel off from anything else.
    static let inset: CGFloat = 8
    /// The icon column, the gap after it, and the icon in it. Every row uses
    /// these, so icons and titles line up down the whole column.
    static let iconColumn: CGFloat = 22
    static let iconGap: CGFloat = 12
    static let iconSize: CGFloat = 15
    /// Light, with the titles: the column reads quiet, and the icons are
    /// white enough not to fade at that stroke.
    static let iconWeight: Font.Weight = .light
    static let titleWeight: Font.Weight = .light
    /// A touch of air between letters, which light type at 12pt needs.
    static let titleTracking: CGFloat = 0.3
    /// The buttons at a row's end.
    static let trailingIconSize: CGFloat = 13
    /// What sits under a row -- a server's tunnels -- one step smaller than
    /// the row itself, so the two levels read apart.
    static let childTitleSize: CGFloat = 13
    static let childIconSize: CGFloat = 15

    @Environment(Theme.self) private var theme
    let isHovering: Bool
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.text.opacity(0.12)
                          : isHovering ? theme.hover : .clear)
            }
    }
}

extension Image {
    /// Fitted into the square every sidebar icon shares, centred in the
    /// column. Symbols differ in shape -- a keyboard is twice as wide as a
    /// lock -- and drawn at one font size, wide ones spill past the column
    /// and nothing lines up. The pages pick squarish symbols for the same
    /// reason.
    @MainActor func sidebarIcon(size: CGFloat = SidebarRowStyle.iconSize) -> some View {
        resizable()
            .scaledToFit()
            .fontWeight(SidebarRowStyle.iconWeight)
            .frame(width: size, height: size)
            .frame(width: SidebarRowStyle.iconColumn)
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
    /// Nil shows the row dimmed and inert: there is nothing it could add.
    let action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SidebarRowStyle.iconGap) {
            Image(systemName: "plus")
                .sidebarIcon(size: SidebarRowStyle.iconSize - 2)
            Text(title)
                .font(theme.ui(12, weight: SidebarRowStyle.titleWeight))
                .tracking(SidebarRowStyle.titleTracking)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.secondaryText)
        .opacity(action == nil ? 0.5 : 1)
        .sidebarRow(hovering: isHovering && action != nil)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
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
