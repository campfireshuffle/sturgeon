import Foundation
import CoreGraphics
// r21scroll <x> <y> <dy> <n> — synthetic scroll-wheel events (pixel units) at a point.
let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!, dy = Int32(a[3])!
let n = Int(a[4])!
let mods = a.count > 5 && a[5] == "opt" ? CGEventFlags.maskAlternate : CGEventFlags()
let src = CGEventSource(stateID: .hidSystemState)!
CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
usleep(80_000)
for i in 0..<n {
    let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
    e?.location = CGPoint(x: x, y: y)
    e?.flags = mods
    e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: i == 0 ? 1 : (i == n - 1 ? 4 : 2))
    e?.post(tap: .cghidEventTap)
    usleep(40_000)
}
print("scrolled \(n) x \(dy) at \(Int(x)),\(Int(y))")
