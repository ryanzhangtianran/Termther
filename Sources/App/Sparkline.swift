import SwiftUI

/// A run of percentages as a line over a faint fill, the latest marked with
/// a dot: what a figure has been doing, without axes to read.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    /// The figure at the top edge: 100 for a percentage, less to make a
    /// quiet one's shape visible.
    var ceiling: Double = 100

    var body: some View {
        GeometryReader { geometry in
            let points = Self.points(values, in: geometry.size, ceiling: ceiling)
            if let last = points.last, points.count > 1 {
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
                    }
                    .fill(color.opacity(0.14))
                    Path { path in path.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    Circle().fill(color)
                        .frame(width: 5, height: 5)
                        .position(last)
                }
            }
        }
    }

    /// Spread across the width, 0 at the bottom and `ceiling` at the top,
    /// kept clear of the edges by the dot's radius.
    static func points(_ values: [Double], in size: CGSize, ceiling: Double = 100) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let inset: CGFloat = 2.5
        return values.enumerated().map { index, value in
            CGPoint(x: inset + (size.width - 2 * inset) * CGFloat(index) / CGFloat(values.count - 1),
                    y: inset + (size.height - 2 * inset) * (1 - CGFloat(min(max(value, 0), ceiling) / ceiling)))
        }
    }
}
