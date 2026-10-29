import Foundation
import CoreGraphics
// r21move x1 y1 x2 y2 n — post n mouse-moved events from (x1,y1) to (x2,y2), 5 ms apart.
let a = CommandLine.arguments
let x1 = Double(a[1])!, y1 = Double(a[2])!, x2 = Double(a[3])!, y2 = Double(a[4])!
let n = Int(a[5])!
let src = CGEventSource(stateID: .hidSystemState)!
for i in 0...n {
    let t = Double(i) / Double(max(n, 1))
    let p = CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(5_000)
}
