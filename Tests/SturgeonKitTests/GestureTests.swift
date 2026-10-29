import CoreGraphics
import XCTest
@testable import SturgeonKit

/// The gesture's decisions are pure: a scroll delta becomes a scale, the scale is clamped and
/// snapped, and a point is either in the strip's gutter or it is not.  No WindowManager needed.
final class GestureTests: XCTestCase {
    // MARK: - scale sequence

    func testScrollUpFromNaturalStepsDownThroughTheSnapZone() {
        var gesture = ScaleGesture(scale: 1.0)
        XCTAssertEqual(gesture.scale, 1.0)

        // One notch up: -1 * notchStep is negative, so the strip shrinks, as r21gesture did.
        XCTAssertEqual(gesture.add(ScaleGesture.step(scrollDelta: 1, precise: false)), 1.0,
                       "2% off natural is still natural")
        XCTAssertEqual(gesture.raw, 0.98)

        // The accumulator keeps moving, so the next notch leaves the snap zone rather than
        // bouncing back to 1.0 forever (the bug this split accumulator exists to prevent).
        XCTAssertEqual(gesture.add(ScaleGesture.step(scrollDelta: 1, precise: false)), 0.96)
        XCTAssertEqual(gesture.add(ScaleGesture.step(scrollDelta: 1, precise: false)), 0.94)
        XCTAssertEqual(gesture.add(ScaleGesture.step(scrollDelta: -1, precise: false)), 0.96)
        XCTAssertEqual(gesture.add(ScaleGesture.step(scrollDelta: -1, precise: false)), 1.0,
                       "coming back through the zone lands exactly on natural")
        XCTAssertEqual(gesture.add(ScaleGesture.step(scrollDelta: -1, precise: false)), 1.0)
    }

    func testPreciseDeltasAreSmallerThanNotches() {
        XCTAssertEqual(ScaleGesture.step(scrollDelta: 10, precise: true), -0.02, accuracy: 1e-12)
        XCTAssertEqual(ScaleGesture.step(scrollDelta: 10, precise: false), -0.2, accuracy: 1e-12)
        XCTAssertEqual(ScaleGesture.step(scrollDelta: 0, precise: true), 0)
    }

    func testClampIsInclusiveAtFourtyAndOneFifty() {
        XCTAssertEqual(ScaleGesture.clamp(0.1), 0.4)
        XCTAssertEqual(ScaleGesture.clamp(9.0), 1.5)
        XCTAssertEqual(ScaleGesture.clamp(0.4), 0.4)
        XCTAssertEqual(ScaleGesture.clamp(1.5), 1.5)

        var gesture = ScaleGesture(scale: 1.0)
        for _ in 0..<500 { gesture.add(-0.1) }
        XCTAssertEqual(gesture.raw, 0.4)
        XCTAssertEqual(gesture.scale, 0.4)

        for _ in 0..<500 { gesture.add(0.1) }
        XCTAssertEqual(gesture.raw, 1.5)
        XCTAssertEqual(gesture.scale, 1.5)
    }

    func testSnapZoneIsTwoPercentEitherSide() {
        XCTAssertEqual(ScaleGesture.snap(0.98), 1.0)
        XCTAssertEqual(ScaleGesture.snap(1.02), 1.0)
        XCTAssertEqual(ScaleGesture.snap(0.9799), 0.9799)
        XCTAssertEqual(ScaleGesture.snap(1.0201), 1.0201)
    }

    func testResetReturnsTheAccumulatorToNatural() {
        var gesture = ScaleGesture(scale: 1.4)
        gesture.add(-0.2)
        gesture.reset()
        XCTAssertEqual(gesture.scale, 1.0)
        XCTAssertEqual(gesture.raw, 1.0)
    }

    // MARK: - rate limit

    func testOneStepPerSixteenMilliseconds() {
        var limiter = EventRateLimiter()
        XCTAssertTrue(limiter.accept(now: 100.000))
        XCTAssertFalse(limiter.accept(now: 100.001))
        XCTAssertFalse(limiter.accept(now: 100.015))
        XCTAssertTrue(limiter.accept(now: 100.016))
        XCTAssertFalse(limiter.accept(now: 100.020))
        XCTAssertTrue(limiter.accept(now: 100.032))

        limiter.reset()
        XCTAssertTrue(limiter.accept(now: 100.033))
    }

    // MARK: - gutter

    func testGutterContainsOnlyPointsInsideTheStripBand() {
        // The strip's own accessibility frame, as stagepilot prints it.
        let gutter = StripGutter(rect: CGRect(x: 0, y: 0, width: 286.92, height: 945))
        XCTAssertTrue(gutter.contains(CGPoint(x: 16, y: 490)))
        XCTAssertTrue(gutter.contains(CGPoint(x: 0, y: 0)))
        XCTAssertTrue(gutter.contains(CGPoint(x: 286.91, y: 944.99)))
        XCTAssertFalse(gutter.contains(CGPoint(x: 287, y: 490)))
        XCTAssertFalse(gutter.contains(CGPoint(x: 16, y: 946)))
        XCTAssertFalse(gutter.contains(CGPoint(x: -1, y: 490)))
    }

    func testCollapsedStripHasNoGutter() {
        XCTAssertFalse(StripGutter(rect: .zero).contains(.zero))
        XCTAssertFalse(StripGutter(rect: CGRect(x: 16, y: 400, width: 0, height: 0))
            .contains(CGPoint(x: 16, y: 400)))
    }

    func testBandFallbackStopsAtTheMeasuredWidth() {
        let gutter = StripGutter.band(screen: CGRect(x: 0, y: 0, width: 1512, height: 945))
        XCTAssertTrue(gutter.contains(CGPoint(x: 300, y: 900)))
        XCTAssertFalse(gutter.contains(CGPoint(x: 400, y: 900)))
    }

    // MARK: - modifier

    func testDefaultChordIsControlPlusOption() {
        XCTAssertEqual(GestureModifier.standard, [.control, .option])
        XCTAssertTrue(GestureModifier.standard.satisfied(by: [.control, .option]))
        XCTAssertFalse(GestureModifier.standard.satisfied(by: [.control]))
        XCTAssertFalse(GestureModifier.standard.satisfied(by: [.option]))
        XCTAssertFalse(GestureModifier.standard.satisfied(by: [.control, .option, .shift]),
                       "an extra relevant modifier must not arm the gesture")
        XCTAssertFalse(GestureModifier().satisfied(by: [.control, .option]),
                       "an empty chord never matches")
    }

    func testModifierLabelsAndPresets() {
        XCTAssertEqual(GestureModifier.standard.label, "Control + Option")
        XCTAssertEqual(GestureModifier.presets.first, .standard)
        XCTAssertEqual(GestureModifier.presets.count, 4)
        XCTAssertEqual(GestureModifier(rawValue: GestureModifier.standard.rawValue), .standard)
    }
}
