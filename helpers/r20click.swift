import Foundation
import CoreGraphics
// r20click <x> <y> — left click at a screen point (CGEvent, HID tap)
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
let p = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .hidSystemState)!
CGWarpMouseCursorPosition(p)
CGAssociateMouseAndMouseCursorPosition(1)
usleep(40_000)
for t in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40_000)
}
print("clicked \(Int(x)),\(Int(y))")
