import AppKit
import ApplicationServices
import CoreGraphics
import SturgeonKit

/// The one input tap the app installs while armed.
///
/// It does two jobs:
///   * **scale** — Control+Option (configurable) + scroll while the pointer is inside the strip's
///     gutter.  The event is consumed only for that exact combination; every other scroll passes
///     through untouched, so other apps keep their zoom.
///   * **drop** — observe mouse-down / drag / up and report a release inside the strip.  Mouse
///     events always pass through: the native drag-out gesture must not be disturbed.
///
/// The tap is active (`defaultTap`), so macOS can disable it on timeout; the tap-disabled
/// callback re-enables it and counts the re-arm.
final class InputTapController {
    /// Set by the model; no tap is installed while disarmed.
    var armed = false {
        didSet {
            guard oldValue != armed else { return }
            armed ? installIfNeeded() : uninstall()
        }
    }
    var gestureEnabled = true
    var modifier: GestureModifier = .standard {
        didSet {
            guard oldValue != modifier else { return }
            onStateChange?(statusText)
        }
    }
    /// The strip rect from the WindowManager's accessibility tree, read at refresh time.
    var gutter: CGRect?

    var onScale: ((Double) -> Void)?
    var onGestureEnd: ((Double) -> Void)?
    var onDrop: ((CGPoint, CGWindowID?) -> Void)?
    var onStateChange: ((String) -> Void)?

    private(set) var rearmCount = 0
    private(set) var installed = false
    private(set) var lastInstallFailure: String?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = ScaleGesture()
    private var limiter = EventRateLimiter()
    private var endWork: DispatchWorkItem?
    private var gestureActive = false

    private var downPoint: CGPoint?
    private var dragged = false
    private var downWindow: CGWindowID?

    // MARK: - lifecycle

    func installIfNeeded() {
        guard armed, tap == nil else { return }
        var mask: CGEventMask = 0
        for type in [CGEventType.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastInstallFailure = permissionSummary
            onStateChange?("off — \(permissionSummary)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
        installed = true
        lastInstallFailure = nil
        onStateChange?(statusText)
    }

    func uninstall() {
        endWork?.cancel()
        endWork = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        installed = false
        gestureActive = false
        limiter.reset()
        onStateChange?(statusText)
    }

    /// A tap that macOS disabled (timeout, sleep/wake) is silently dead until re-enabled.
    func ensureEnabled() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            rearmCount += 1
            onStateChange?(statusText)
        }
    }

    /// The payload's current scale, so the next gesture starts from what is on screen.  A value
    /// that matches the snapped scale is not a change: resetting the accumulator to the snapped
    /// 1.0 here would make an isolated wheel notch (raw 0.98 → emitted 1.0) repeat forever and the
    /// strip could never shrink past the snap zone.
    func setBaseScale(_ value: Double) {
        guard !gestureActive else { return }
        guard abs(gesture.scale - value) >= 0.005 else { return }
        gesture = ScaleGesture(scale: value)
    }

    var permissionSummary: String {
        let accessibility = AXIsProcessTrusted()
        let listening = CGPreflightListenEventAccess()
        var missing: [String] = []
        if !accessibility { missing.append("Accessibility") }
        if !listening { missing.append("Input Monitoring") }
        return missing.isEmpty ? "permissions granted" : "needs " + missing.joined(separator: " + ")
    }

    var statusText: String {
        if !armed { return "off (disarmed)" }
        if !installed { return "off — \(lastInstallFailure ?? permissionSummary)" }
        if !gestureEnabled { return "drop only (gesture disabled)" }
        return "listening (\(modifier.label))"
    }

    /// Ask for both consents.  Accessibility is what an active tap needs; Input Monitoring is
    /// what current macOS additionally records for a global event tap.
    func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        onStateChange?(statusText)
    }

    // MARK: - events

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                rearmCount += 1
                onStateChange?(statusText)
            }
            return nil
        }

        guard armed else { return pass }
        let point = event.location

        switch type {
        case .scrollWheel:
            guard gestureEnabled,
                  modifier.satisfied(by: Self.modifiers(event.flags)),
                  let gutter,
                  StripGutter(rect: gutter).contains(point)
            else { return pass }

            let now = ProcessInfo.processInfo.systemUptime
            // Consume even a throttled event: while the chord is held over the strip the scroll
            // belongs to us, not to the app underneath.
            guard limiter.accept(now: now) else { return nil }

            if !gestureActive {
                gestureActive = true
                gesture = ScaleGesture(scale: gesture.scale)
            }
            let precise = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let delta = precise
                ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let scale = gesture.add(ScaleGesture.step(scrollDelta: delta, precise: precise))
            onScale?(scale)
            scheduleEnd()
            return nil

        case .leftMouseDown:
            downPoint = point
            dragged = false
            downWindow = WindowProbe.window(at: point)
            return pass

        case .leftMouseDragged:
            if let down = downPoint, !dragged,
               hypot(point.x - down.x, point.y - down.y) > 4 {
                dragged = true
            }
            return pass

        case .leftMouseUp:
            let wasDragged = dragged
            let window = downWindow
            downPoint = nil
            dragged = false
            downWindow = nil
            if wasDragged, let gutter, StripGutter(rect: gutter).contains(point) {
                onDrop?(point, window)
            }
            return pass

        default:
            return pass
        }
    }

    /// The gesture ends when the scroll stops.  The accumulator is deliberately *not* reset to
    /// the snapped value: a slow wheel sends one notch per gesture, and resetting would make the
    /// 2% snap zone act as a wall.  The final value is written through the same direct path.
    private func scheduleEnd() {
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.gestureActive = false
            self.limiter.reset()
            self.onGestureEnd?(self.gesture.scale)
        }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    static func modifiers(_ flags: CGEventFlags) -> GestureModifier {
        var result: GestureModifier = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }
}

private func inputTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<InputTapController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

/// The dragged window, captured at mouse-down.  Bounds and window numbers are available without
/// Screen Recording; only window *titles* are restricted, and none are read here.
enum WindowProbe {
    /// Owners that are part of the desktop itself.  A press on the strip (a tile drag, a stage
    /// reorder) must never be mistaken for a dragged application window.
    private static let systemOwners: Set<String> = [
        "com.apple.WindowManager",
        "com.apple.WindowServer",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
    ]

    static func window(at point: CGPoint) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        for row in rows {
            guard let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else {
                continue
            }
            guard let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
                continue
            }
            if owner == mine { continue }
            if let bundle = NSRunningApplication(processIdentifier: pid_t(owner))?.bundleIdentifier,
               systemOwners.contains(bundle) {
                continue
            }
            if let name = row[kCGWindowOwnerName as String] as? String,
               name == "Window Server" || name == "WindowManager" || name == "Dock" {
                continue
            }
            guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = Self.rect(bounds) else { continue }
            if frame.width >= 40, frame.height >= 40, frame.contains(point),
               let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                return number
            }
        }
        return nil
    }

    private static func rect(_ bounds: [String: Any]) -> CGRect? {
        func value(_ key: String) -> CGFloat? {
            (bounds[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        guard let x = value("X"), let y = value("Y"),
              let width = value("Width"), let height = value("Height") else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
