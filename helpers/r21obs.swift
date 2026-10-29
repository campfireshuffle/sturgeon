import Cocoa
import Foundation
import CoreGraphics

// r21obs — out-of-process observer for the round-21 strip-resize work.
// Publishes every ~25 ms what a root debug session cannot see: which windows are in the
// left rail (the Stage Manager strip), their on-screen frames, and whether a flush
// full-size window is frontmost.  Kept deliberately close to round 20's r20obs so the
// in-WM keeper reads the same signals.
//
// usage: r21obs [--out /tmp/r21/state.json] [--rail 320] [--minw 1200]

setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
func opt(_ n: String, _ d: String) -> String {
    if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }
    return d
}
let OUT = opt("--out", "/tmp/r21/state.json")
let RAIL = Double(opt("--rail", "320"))!
let MINW = Double(opt("--minw", "1200"))!

let skip: Set<String> = ["WindowManager", "Window Server", "Dock", "Control Center", "Notification Center",
                         "CursorUIViewService", "Wallpaper", "Spotlight", "TextInputMenuAgent",
                         "SystemUIServer", "loginwindow", "SecurityAgent"]

var known: [Int: Double] = [:]
var seenOwner: [Int: String] = [:]

func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
}

func frameOf(_ w: [String: Any]) -> CGRect {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return CGRect(x: b["X"] as? Double ?? 0, y: b["Y"] as? Double ?? 0,
                  width: b["Width"] as? Double ?? 0, height: b["Height"] as? Double ?? 0)
}

let t0 = Date()
while true {
    let ws = windows()
    var front: (String, CGRect)? = nil
    var rail: [Int] = []
    var rails: [[String: Any]] = []
    let now = Date().timeIntervalSince(t0)
    for w in ws {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        let f = frameOf(w)
        if f.width <= 0 || f.height <= 0 { continue }
        if layer != 0 && layer != 3 { continue }
        if layer == 0, front == nil, !skip.contains(owner), f.width >= 600, f.height >= 300 {
            front = (owner, f)
        }
        if f.minX > -420, f.maxX <= RAIL, f.width <= RAIL, f.height <= 520, f.width <= 320,
           !skip.contains(owner) || owner == "WindowManager" {
            rail.append(num)
            known[num] = now
            seenOwner[num] = owner
        }
    }
    var big = Set<Int>()
    for w in ws {
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        let f = frameOf(w)
        if f.width > 500 || f.height > 600 { big.insert(num) }
    }
    for (k, t) in known where now - t > 10 || big.contains(k) { known[k] = nil }
    var ids = Set(rail)
    for k in known.keys { ids.insert(k) }
    // rail_now: only windows actually *drawn* inside the strip's gutter right now.  Windows that
    // the WM parks just off the left edge (its gesture blocking overlays at x = -7) are excluded:
    // they are not strip items and must keep their poses.
    var railNow: [Int] = []
    for w in ws {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        let f = frameOf(w)
        if layer != 0 && layer != 3 { continue }
        if skip.contains(owner) && owner != "WindowManager" { continue }
        if f.minX >= 0, f.maxX <= 300, f.width >= 8, f.width <= 300, f.height >= 8, f.height <= 560 {
            railNow.append(num)
        }
    }
    // current on-screen frames of the remembered strip windows
    for w in ws {
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        if !ids.contains(num) { continue }
        let f = frameOf(w)
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        rails.append(["id": num, "owner": owner, "x": f.minX, "y": f.minY,
                      "w": f.width, "h": f.height,
                      "on": (f.minX >= 0 && f.maxX <= RAIL && f.width > 0) ? 1 : 0])
    }
    let flush = front.map { $0.1.minX <= 2 && $0.1.width >= MINW } ?? false
    var onCount = 0
    for w in ws {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let f = frameOf(w)
        if layer != 0 && layer != 3 { continue }
        if f.minX >= 0, f.maxX <= RAIL, f.width <= RAIL, f.height <= 520, f.width > 20,
           !skip.contains(owner) || owner == "WindowManager" { onCount += 1 }
    }
    let stripOn = onCount >= 2
    let fr = front.map { "\($0.0) \(Int($0.1.minX)) \(Int($0.1.minY)) \(Int($0.1.width)) \(Int($0.1.height))" } ?? "-"
    let frontX = front?.1.minX ?? -1
    let obj: [String: Any] = ["flush": flush, "strip_ids": ids.sorted(),
                              "rail_now": railNow.sorted(), "front": fr,
                              "strip_on": stripOn, "rail_on": onCount, "front_x": frontX,
                              "rail": rails, "t": Date().timeIntervalSince1970]
    if let d = try? JSONSerialization.data(withJSONObject: obj) {
        let tmp = OUT + ".tmp"
        try? d.write(to: URL(fileURLWithPath: tmp))
        try? FileManager.default.removeItem(atPath: OUT)
        try? FileManager.default.moveItem(atPath: tmp, toPath: OUT)
    }
    usleep(25_000)
}
