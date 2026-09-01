import Foundation
import QuartzCore

/// Slides the cursor between cells instead of teleporting.
///
/// A caret that eases into place is much easier to follow with the eye,
/// especially when a line edit moves it several columns at once. But easing is
/// only right for *small* moves: when a program switches screens, pages, or
/// redraws, the cursor can legitimately end up anywhere, and animating across
/// that distance makes it look lost rather than smooth. Past a threshold the
/// cursor snaps.
public struct CursorMotion {
    /// Grid cells. Beyond this a move is treated as a jump, not a motion.
    public var snapDistance: Double = 8
    public var duration: TimeInterval

    private var from = SIMD2<Double>()
    private var target: SIMD2<Double>?
    private var startedAt: CFTimeInterval = 0

    /// The clock. Injectable so tests can step time exactly instead of
    /// sleeping, which under a parallel test run overshoots the animation and
    /// makes an interpolation check fail for no reason.
    private let now: @Sendable () -> CFTimeInterval

    public init(duration: TimeInterval = 0.08,
                now: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.duration = duration
        self.now = now
    }

    /// Where the cursor should be drawn now, in fractional grid cells.
    public private(set) var visual = SIMD2<Double>()

    /// True while an ease is in flight, so the view keeps redrawing even though
    /// the terminal itself has not changed.
    public var isAnimating: Bool {
        guard target != nil, duration > 0 else { return false }
        return now() - startedAt < duration
    }

    /// Points the motion at a new grid position.
    public mutating func move(to position: SIMD2<Double>) {
        defer { target = position }

        // First sighting, animation disabled, or a jump: be where we are told.
        guard duration > 0, let previous = target else {
            visual = position
            return
        }
        guard position != previous else { return }

        let distance = (position - visual)
        if (distance * distance).sum().squareRoot() > snapDistance {
            visual = position
            return
        }

        from = visual
        startedAt = now()
    }

    /// Advances the ease. Call once per frame before drawing.
    public mutating func tick() {
        guard let target, duration > 0 else { return }
        let elapsed = now() - startedAt
        guard elapsed < duration else { visual = target; return }

        // easeOutCubic: quick to leave, gentle to arrive, which reads as the
        // caret settling rather than drifting.
        let t = elapsed / duration
        let eased = 1 - pow(1 - t, 3)
        visual = from + (target - from) * eased
    }
}
