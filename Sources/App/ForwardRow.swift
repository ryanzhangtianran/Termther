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
            TileButton(symbol: status.isLive ? "stop.fill" : "play.fill",
                       color: status.color(stopped: theme.secondaryText),
                       help: status.isLive ? "Stop" : "Start") {
                Task { await forwards.toggle(preset) }
            }

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
        let down = ByteCountFormatter.numeric(stats.bytesIn), up = ByteCountFormatter.numeric(stats.bytesOut)
        return "\(stats.connections) conn  \u{2193}\(down)  \u{2191}\(up)"
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
        case .remote where proxyRole != nil:
            // Its target is the system's proxy, looked up when it starts.
            "server:\(bindPort) \u{2192} this Mac's proxy"
        case .remote:
            // From the server's point of view, because that is whose port it
            // is: its 16152 arrives at our 6152.
            "server:\(bindPort) \u{2192} \(targetHost):\(targetPort)"
        }
    }
}

extension ByteCountFormatter {
    /// A size in figures, in binary units: "0 bytes" rather than the
    /// formatter's "Zero KB".
    @MainActor static func numeric(_ count: some BinaryInteger) -> String {
        binary.string(fromByteCount: Int64(count))
    }

    /// Made once: the traffic rows ask several times each, every second.
    @MainActor private static let binary: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
