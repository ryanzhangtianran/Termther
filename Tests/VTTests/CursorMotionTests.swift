import Foundation
import QuartzCore
import Testing
@testable import VT

@Test("with animation off the cursor is simply where it is told")
func motionDisabled() {
    var motion = CursorMotion(duration: 0)
    motion.move(to: SIMD2(0, 0))
    motion.move(to: SIMD2(5, 3))
    motion.tick()
    #expect(motion.visual == SIMD2(5, 3))
    #expect(!motion.isAnimating)
}

@Test("the first position is adopted immediately, not eased in from nowhere")
func firstPositionSnaps() {
    var motion = CursorMotion(duration: 0.1)
    motion.move(to: SIMD2(10, 4))
    #expect(motion.visual == SIMD2(10, 4))
    #expect(!motion.isAnimating)
}

/// A clock the test drives, so the assertions are about the easing curve and
/// not about how busy the machine was.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: CFTimeInterval = 1000

    var now: @Sendable () -> CFTimeInterval {
        { [self] in lock.lock(); defer { lock.unlock() }; return time }
    }

    func advance(_ seconds: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        time += seconds
    }
}

@Test("a short move eases, passing through the space between the two cells")
func shortMoveEases() {
    let clock = TestClock()
    var motion = CursorMotion(duration: 0.2, now: clock.now)
    motion.move(to: SIMD2(0, 0))
    motion.move(to: SIMD2(4, 0))

    #expect(motion.isAnimating)
    #expect(motion.visual.x == 0, "the ease starts where the cursor was")

    clock.advance(0.06)
    motion.tick()
    let midway = motion.visual.x
    #expect(midway > 0 && midway < 4, "expected to be between the cells, got \(midway)")

    clock.advance(0.2)
    motion.tick()
    #expect(motion.visual == SIMD2(4, 0))
    #expect(!motion.isAnimating)
}

@Test("easing is fast to leave and gentle to arrive")
func easeShape() {
    // easeOutCubic: more than half the distance is covered in the first
    // quarter of the time, which is what makes it read as settling.
    let clock = TestClock()
    var motion = CursorMotion(duration: 0.4, now: clock.now)
    motion.move(to: SIMD2(0, 0))
    motion.move(to: SIMD2(1, 0))

    clock.advance(0.1)
    motion.tick()
    #expect(motion.visual.x > 0.5,
            "expected past halfway at a quarter of the time, got \(motion.visual.x)")

    // And decelerating: the last quarter covers far less ground than the first.
    clock.advance(0.2)
    motion.tick()
    let atThreeQuarters = motion.visual.x
    clock.advance(0.1)
    motion.tick()
    #expect(1 - atThreeQuarters < 0.05, "the arrival should be gentle")
}

@Test("a long jump snaps, because a screen switch is not a movement")
func longJumpSnaps() {
    // Paging, a screen switch or a remote redraw can put the cursor anywhere.
    // Easing across that distance makes the caret look lost rather than smooth.
    var motion = CursorMotion(duration: 0.2)
    motion.move(to: SIMD2(0, 0))
    motion.move(to: SIMD2(60, 20))
    #expect(motion.visual == SIMD2(60, 20))
    #expect(!motion.isAnimating)
}

@Test("the snap threshold is where the behaviour changes")
func snapThreshold() {
    var motion = CursorMotion(duration: 0.2)
    motion.snapDistance = 8

    motion.move(to: SIMD2(0, 0))
    motion.move(to: SIMD2(7, 0))          // inside the threshold
    #expect(motion.isAnimating)
    #expect(motion.visual.x == 0)

    var other = CursorMotion(duration: 0.2)
    other.snapDistance = 8
    other.move(to: SIMD2(0, 0))
    other.move(to: SIMD2(9, 0))           // outside it
    #expect(!other.isAnimating)
    #expect(other.visual.x == 9)
}
