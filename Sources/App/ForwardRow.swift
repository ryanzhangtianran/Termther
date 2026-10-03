import Core
import Foundation
import SwiftUI

/// One tunnel, with its switch, its state and what it has carried.
///
/// Used under a server in the list, where a forward is read in the context of
/// the machine it runs on rather than in a table of its own.
struct ForwardRow: View {
    @Environment(Theme.self) private var theme
    let preset: PortForwardPreset
    @Bindable var forwards: Forwards

    @State private var isHovering = false

    private var status: Forwards.Status { forwards.status(of: preset) }

    var body: some View {
        HStack(spacing: SidebarRowStyle.iconGap) {
            // One button, two meanings, and the icon says which: this is the
            // control people reach for, so it is the largest thing in the row.
            Button {
                Task { await forwards.toggle(preset) }
            } label: {
                Image(systemName: status.isLive ? "stop.fill" : "play.fill")
                    .font(.system(size: SidebarRowStyle.childIconSize - 2, weight: SidebarRowStyle.iconWeight))
                    .foregroundStyle(status.color(stopped: theme.secondaryText))
                    .frame(width: SidebarRowStyle.iconColumn, height: SidebarRowStyle.iconColumn)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // One line: what it forwards. How it is doing is the icon's colour,
            // and the details are on hover.
            Text(preset.summary)
                .font(theme.ui(SidebarRowStyle.childTitleSize))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sidebarRow(hovering: isHovering)
        .onHover { hovering in
            // Eased, so buttons that appear on hover slide in rather than pop.
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
        .help(subtitle)
    }

    /// What it is doing, or why it is not.
    private var subtitle: String {
        if case .failed(let reason) = status { return reason }
        if case .retrying(let reason) = status { return reason }
        guard status == .running, let id = preset.id, let stats = forwards.traffic[id] else {
            return switch preset.direction {
            case .local:   "Local forward"
            case .dynamic: "Dynamic proxy"
            case .remote:  preset.exportsEnvironment ? "Proxy through this Mac" : "Reverse forward"
            }
        }
        return "\(stats.connections) conn  \u{2193}\(bytes(stats.bytesIn))  \u{2191}\(bytes(stats.bytesOut))"
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.numeric(Int64(count), countStyle: .binary)
    }
}

extension Forwards.Status {
    /// Green when running, yellow on the way, orange when broken. Stopped is
    /// left to the caller, because how faint it should be depends on where.
    func color(stopped: SwiftUI.Color) -> SwiftUI.Color {
        switch self {
        case .running:             .green
        case .starting, .retrying: .yellow
        case .failed:              .orange
        case .stopped:             stopped
        }
    }

    /// The reason, when there is one worth reading in full.
    var detail: String? {
        switch self {
        case .failed(let reason), .retrying(let reason): reason
        default: nil
        }
    }
}

extension PortForwardPreset {
    /// One line saying what it does, in the direction it actually runs.
    ///
    /// Defined once because it appears in two places -- the list under a
    /// server and the summary inside the server's editor -- and two spellings
    /// of the same tunnel would read as two different tunnels.
    var summary: String {
        switch direction {
        case .local:
            "\(bindPort) \u{2192} \(targetHost):\(targetPort)"
        case .dynamic:
            "SOCKS5 on \(bindPort)"
        case .remote:
            // From the server's point of view, because that is whose port it
            // is: its 16152 arrives at our 6152.
            "server:\(bindPort) \u{2192} \(targetHost):\(targetPort)"
        }
    }
}

extension ByteCountFormatter {
    /// A size in figures: "0 bytes" rather than the formatter's "Zero KB".
    static func numeric(_ count: Int64, countStyle: CountStyle) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = countStyle
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }
}
