import CoreGraphics
import Foundation

// MARK: - modifier

/// The modifier chord that arms the strip gesture.  Kept independent of AppKit so the matching
/// rule is unit-tested; the app maps `CGEventFlags` into this type.
public struct GestureModifier: OptionSet, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = GestureModifier(rawValue: 1 << 0)
    public static let option = GestureModifier(rawValue: 1 << 1)
    public static let shift = GestureModifier(rawValue: 1 << 2)
    public static let command = GestureModifier(rawValue: 1 << 3)

    /// The modifiers the control cares about.  Caps Lock, Fn and the numeric pad are ignored.
    public static let relevant: GestureModifier = [.control, .option, .shift, .command]

    /// Shipped default: Control + Option.  Option+scroll alone is used for zoom in several apps.
    public static let standard: GestureModifier = [.control, .option]

    public static let presets: [GestureModifier] = [
        [.control, .option],
        [.option],
        [.control, .shift],
        [.option, .command],
    ]

    /// An exact match on the relevant modifiers: holding an extra Command must not silently arm
    /// the gesture.  An empty chord never matches.
    public func satisfied(by held: GestureModifier) -> Bool {
        guard !isEmpty else { return false }
        return held.intersection(.relevant) == intersection(.relevant)
    }

    public var label: String {
        let parts: [(GestureModifier, String)] = [
            (.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command"),
        ]
        let names = parts.filter { contains($0.0) }.map(\.1)
        return names.isEmpty ? "none" : names.joined(separator: " + ")
    }
}

// MARK: - gutter

/// The strip's gutter: the vertical band on the left edge of the display that the WindowManager
/// reserves for stage tiles.  The rect comes from the WindowManager's own accessibility frame
/// (`stagepilot stages` prints `strip=`), so it follows the display and the strip's reveal state.
public struct StripGutter: Equatable {
    public var rect: CGRect

    public init(rect: CGRect) { self.rect = rect }

    public func contains(_ point: CGPoint) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return rect.contains(point)
    }

    /// A conservative fallback used only when the accessibility tree cannot be read: the measured
    /// strip band on the left edge of the display.  The gesture stays off unless a real rect has
    /// been read at least once, so this is not a silent substitute.
    public static func band(screen: CGRect, width: CGFloat = 320) -> StripGutter {
        StripGutter(rect: CGRect(x: screen.minX, y: screen.minY,
                                 width: min(width, screen.width), height: screen.height))
    }
}

// MARK: - scale

/// The scale a scroll gesture drives.  `raw` is the continuous accumulator; `scale` is what the
/// keeper is asked to render after clamping and the 1.0 snap.
///
/// Why a separate accumulator: snapping the stored value would make the control stick at 100%.
/// At raw 0.98 the emitted scale is 1.0 (inside the 2% snap zone); the next notch takes raw to
/// 0.96 and the emitted scale leaves the zone.  Snapping the accumulator would put it back at 1.0
/// on every step and the strip could never shrink past the zone.
public struct ScaleGesture: Equatable {
    public static let minimum = 0.4
    public static let maximum = 1.5
    /// Within 2% of natural, the strip is exactly natural.
    public static let snapZone = 0.02
    /// Precise (trackpad) deltas are pixels; one pixel is a small fraction of a step.
    public static let preciseFactor = 0.002
    /// One non-precise wheel notch.
    public static let notchStep = 0.02

    public private(set) var raw: Double

    public init(scale: Double = 1.0) {
        raw = Self.clamp(scale)
    }

    /// The value handed to the payload: clamped, then snapped.
    public var scale: Double { Self.snap(Self.clamp(raw)) }

    @discardableResult
    public mutating func add(_ delta: Double) -> Double {
        raw = Self.clamp(raw + delta)
        return scale
    }

    public mutating func reset(to value: Double = 1.0) {
        raw = Self.clamp(value)
    }

    public static func clamp(_ value: Double) -> Double {
        min(maximum, max(minimum, value))
    }

    public static func snap(_ value: Double) -> Double {
        abs(value - 1.0) <= snapZone + 1e-9 ? 1.0 : value
    }

    /// Scroll up (positive delta) shrinks, matching the demonstrated `r21gesture` direction.
    public static func step(scrollDelta delta: Double, precise: Bool) -> Double {
        precise ? -delta * preciseFactor : -delta * notchStep
    }
}

// MARK: - rate limit

/// One accepted step per 16 ms: a trackpad can deliver several hundred events a second and the
/// payload should see ~60 updates a second, not every frame of the gesture.
public struct EventRateLimiter: Equatable {
    public let interval: TimeInterval
    private var last: TimeInterval?

    public init(interval: TimeInterval = 0.016) {
        self.interval = interval
    }

    public mutating func accept(now: TimeInterval) -> Bool {
        if let last, now - last < interval - 1e-9 { return false }
        last = now
        return true
    }

    public mutating func reset() { last = nil }
}
