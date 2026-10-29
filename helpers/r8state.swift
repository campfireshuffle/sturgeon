import Cocoa
import Foundation
import ApplicationServices

// r8state — one-shot observation for the round-8 harness.
// usage: r8state <owner> [--json]
//
// Prints, machine-readably:
//   WIN <wid> on=<0|1> f=<x>,<y> <w>x<h> layer=<l> name=<title>
//   PILE <title> ids=[..] frame=<x>,<y>,<w>,<h>
//   STRIP <out|hidden> frame=...
// Piles are the WM's own strip list; *the current stage is the one that is not a pile*.
setvbuf(stdout, nil, _IONBF, 0)

let argv = CommandLine.arguments
guard argv.count > 1 else { print("usage: r8state <owner>"); exit(1) }
let owner = argv[1]
let json = argv.contains("--json")

func axAttr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func axStr(_ e: AXUIElement, _ n: String) -> String { (axAttr(e, n) as? String) ?? "" }
func axKids(_ e: AXUIElement) -> [AXUIElement] { (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axFrame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = axAttr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = axAttr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func find(_ e: AXUIElement, _ id: String, _ d: Int = 0) -> AXUIElement? {
    if d > 6 { return nil }
    if axStr(e, "AXIdentifier") == id { return e }
    for c in axKids(e) { if let r = find(c, id, d + 1) { return r } }
    return nil
}

struct Win { let wid: Int; let on: Bool; let x: Double; let y: Double; let w: Double; let h: Double; let name: String; let owner: String; let layer: Int }
struct Pile { let title: String; let ids: [Int]; let r: CGRect }

var wins: [Win] = []
if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String ?? "") == owner || owner == "*" else { continue }
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        guard layer >= 0 && layer <= 10 else { continue }   // 0 = normal, 1..10 = panels/floating
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        wins.append(Win(wid: w[kCGWindowNumber as String] as? Int ?? -1,
                        on: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                        x: b["X"] as? Double ?? -1, y: b["Y"] as? Double ?? -1,
                        w: b["Width"] as? Double ?? -1, h: b["Height"] as? Double ?? -1,
                        name: w[kCGWindowName as String] as? String ?? "",
                        owner: w[kCGWindowOwnerName as String] as? String ?? "",
                        layer: layer))
    }
}

var piles: [Pile] = []
var stripOut = false
var stripFrame = CGRect.zero
if let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first,
   let strip = find(AXUIElementCreateApplication(wm.processIdentifier), "sm.strip") {
    stripFrame = axFrame(strip)
    stripOut = stripFrame.origin.x >= 0 && stripFrame.width > 100 && stripFrame.height > 50
    // Enumerate the tiles even while the strip is retracted: the AX list is present
    // with x < 0, which is a *non-disturbing* way to read stage membership.
    for el in axKids(strip) where axStr(el, kAXRoleAttribute) == kAXButtonRole {
        let ids = (axAttr(el, "AXWindowsIDs") as? [NSNumber])?.map { $0.intValue } ?? []
        piles.append(Pile(title: axStr(el, kAXTitleAttribute), ids: ids, r: axFrame(el)))
    }
}

if json {
    let o: [String: Any] = [
        "owner": owner,
        "strip": stripOut,
        "wins": wins.map { ["wid": $0.wid, "on": $0.on, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h, "name": $0.name, "owner": $0.owner, "layer": $0.layer] },
        "piles": piles.map { ["title": $0.title, "ids": $0.ids, "x": Double($0.r.origin.x), "y": Double($0.r.origin.y), "w": Double($0.r.width), "h": Double($0.r.height)] },
    ]
    let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    print(String(data: d, encoding: .utf8)!)
} else {
    print("STRIP \(stripOut ? "out" : "hidden") frame=\(Int(stripFrame.origin.x)),\(Int(stripFrame.origin.y)),\(Int(stripFrame.width))x\(Int(stripFrame.height))")
    for p in piles {
        print("PILE '\(p.title)' ids=\(p.ids) frame=\(Int(p.r.origin.x)),\(Int(p.r.origin.y)),\(Int(p.r.width))x\(Int(p.r.height))")
    }
    for w in wins.sorted(by: { $0.wid < $1.wid }) {
        print("WIN \(w.wid) on=\(w.on ? 1 : 0) f=\(Int(w.x)),\(Int(w.y)) \(Int(w.w))x\(Int(w.h)) \(w.name) [\(w.owner)]")
    }
}
