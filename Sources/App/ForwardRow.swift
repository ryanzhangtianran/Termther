import Core
import SwiftUI

/// One tunnel, with its switch, its state and what it has carried.
///
/// Used under a server in the list, where a forward is read in the context of
/// the machine it runs on rather than in a table of its own.
struct ForwardRow: View {
    @Environment(Theme.self) private var theme
    let preset: PortForwardPreset
    @Bindable var forwards: Forwards
    let edit: (() -> Void)?

    @State private var isHovering = false

    private var status: Forwards.Status { forwards.status(of: preset) }

    var body: some View {
        HStack(spacing: 8) {
            // One button, two meanings, and the icon says which: this is the
            // control people reach for, so it is the largest thing in the row.
            Button {
                Task { await forwards.toggle(preset) }
            } label: {
                Image(systemName: status.isLive ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(indicator)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(preset.summary)
                    .font(theme.ui(13))
                    .lineLimit(1)
                Text(subtitle)
                    .font(theme.ui(11))
                    .foregroundStyle(subtitleColour)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { edit?() }

            if isHovering, let edit {
                action("pencil", "Edit", edit)
            }
        }
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
        .help(status.detail ?? "")
    }

    /// What it is doing, or why it is not.
    private var subtitle: String {
        if case .failed(let reason) = status { return reason }
        if case .retrying(let reason) = status { return reason }
        guard status == .running, let id = preset.id, let stats = forwards.traffic[id] else {
            return switch preset.direction {
            case .local:   "Local forward"
            case .dynamic: "Dynamic proxy"
            case .remote:  "Reverse forward"
            }
        }
        return "\(stats.connections) conn  \u{2193}\(bytes(stats.bytesIn))  \u{2191}\(bytes(stats.bytesOut))"
    }

    private var subtitleColour: Color {
        switch status {
        case .failed:   .orange
        case .retrying: .yellow
        default:        theme.secondaryText
        }
    }

    private var indicator: Color {
        switch status {
        case .running:  .green
        case .starting: .yellow
        case .retrying: .yellow
        case .failed:   .orange
        case .stopped:  theme.secondaryText
        }
    }

    private func action(_ icon: String, _ title: String,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.secondaryText)
        .help(title)
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
}

extension Forwards.Status {
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
