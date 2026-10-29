import Cocoa
import Foundation
import ApplicationServices

// r19ax — AX access by CGWindowID for the round-19 move trials.
//   r19ax list                       every AX window: pid, cgid, owner, title, frame
//   r19ax nudge <cgid> <dx> <dy>     move that window by (dx,dy) and back; prints frames
//   r19ax raise <cgid>               AXRaise the window
//   r19ax close <cgid>               press its AX close button
//   r19ax frame <cgid>               print its AX frame
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ w: UnsafeMutablePointer<UInt32>) -> AXError

setvbuf(stdout, nil, _IONBF, 0)

func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ n: String) -> String { (attr(e, n) as? String) ?? "" }
func frameOf(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func setFrame(_ e: AXUIElement, _ r: CGRect) {
    var p = r.origin, s = r.size
    let pv = AXValueCreate(.cgPoint, &p)!
    let sv = AXValueCreate(.cgSize, &s)!
    AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, pv)
    AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sv)
}

struct Item { let pid: pid_t; let cgid: UInt32; let owner: String; let title: String; let el: AXUIElement; let frame: CGRect }

func all() -> [Item] {
    var out: [Item] = []
    for app in NSWorkspace.shared.runningApplications {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let wins = attr(ax, kAXWindowsAttribute) as? [AXUIElement] else { continue }
        for w in wins {
            var cg: UInt32 = 0
            _ = _AXUIElementGetWindow(w, &cg)
            out.append(Item(pid: app.processIdentifier, cgid: cg,
                            owner: app.localizedName ?? "?", title: str(w, kAXTitleAttribute),
                            el: w, frame: frameOf(w)))
        }
    }
    return out
}

let a = CommandLine.arguments
guard a.count > 1 else { print("usage: r19ax list|nudge|raise|close|frame ..."); exit(2) }
switch a[1] {
case "list":
    for it in all().sorted(by: { $0.cgid < $1.cgid }) {
        print("AX pid=\(it.pid) cgid=\(it.cgid) owner=\(it.owner) f=\(Int(it.frame.origin.x)),\(Int(it.frame.origin.y)) \(Int(it.frame.width))x\(Int(it.frame.height)) title=\(it.title)")
    }
case "nudge":
    let cg = UInt32(a[2])!, dx = Double(a[3])!, dy = Double(a[4])!
    guard let it = all().first(where: { $0.cgid == cg }) else { print("no ax window cgid=\(cg)"); exit(3) }
    let f0 = it.frame
    setFrame(it.el, CGRect(x: f0.origin.x + dx, y: f0.origin.y + dy, width: f0.width, height: f0.height))
    usleep(120_000)
    let f1 = it.frame
    setFrame(it.el, f0)
    usleep(120_000)
    let f2 = it.frame
    print("nudge cgid=\(cg) \(Int(f0.origin.x)),\(Int(f0.origin.y)) -> \(Int(f1.origin.x)),\(Int(f1.origin.y)) -> \(Int(f2.origin.x)),\(Int(f2.origin.y)) size=\(Int(f2.width))x\(Int(f2.height))")
case "raise":
    let cg = UInt32(a[2])!
    guard let it = all().first(where: { $0.cgid == cg }) else { print("no ax window cgid=\(cg)"); exit(3) }
    print("raise cgid=\(cg) err=\(AXUIElementPerformAction(it.el, kAXRaiseAction as CFString).rawValue)")
case "close":
    let cg = UInt32(a[2])!
    guard let it = all().first(where: { $0.cgid == cg }) else { print("no ax window cgid=\(cg)"); exit(3) }
    if let b = attr(it.el, kAXCloseButtonAttribute) {
        print("close cgid=\(cg) title=\(it.title) err=\(AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString).rawValue)")
    } else { print("no close button cgid=\(cg)"); exit(4) }
case "front":
    guard let app = NSWorkspace.shared.frontmostApplication else { print("no front app"); exit(3) }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var winsRef: CFTypeRef?
    var el: AXUIElement?
    if let v = attr(ax, kAXFocusedWindowAttribute) { el = (v as! AXUIElement) } else if
        AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsRef) == .success,
        let ws = winsRef as? [AXUIElement] { el = ws.first }
    guard let w = el else { print("no window for \(app.localizedName ?? "?")"); exit(3) }
    var cg: UInt32 = 0
    _ = _AXUIElementGetWindow(w, &cg)
    let f = frameOf(w)
    print("cgid=\(cg) owner=\(app.localizedName ?? "?") title=\(str(w, kAXTitleAttribute)) f=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))")
case "tiles":
    if let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first {
        func idStr(_ e: AXUIElement) -> String { (attr(e, "AXIdentifier") as? String) ?? "" }
        func findStrip(_ e: AXUIElement, _ d: Int = 0) -> AXUIElement? {
            if d > 6 { return nil }
            if idStr(e) == "sm.strip" { return e }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
                if let r = findStrip(c, d + 1) { return r }
            }
            return nil
        }
        if let strip = findStrip(AXUIElementCreateApplication(wm.processIdentifier)) {
            for el in (attr(strip, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
                let ids = (attr(el, "AXWindowsIDs") as? [NSNumber])?.map { $0.intValue } ?? []
                let f = frameOf(el)
                var acts: CFArray?
                AXUIElementCopyActionNames(el, &acts)
                print("TILE ids=\(ids) f=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height)) title=\(str(el, kAXTitleAttribute)) actions=\((acts as? [String]) ?? [])")
            }
        }
    }
case "clickids":
    // r19ax clickids 399,434,57 — CG-click the stage tile whose AXWindowsIDs match
    let want = a[2].split(separator: ",").compactMap { Int($0) }.sorted()
    guard let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else {
        print("no WindowManager"); exit(3)
    }
    let app = AXUIElementCreateApplication(wm.processIdentifier)
    func idStr(_ e: AXUIElement) -> String { (attr(e, "AXIdentifier") as? String) ?? "" }
    func findStrip(_ e: AXUIElement, _ d: Int = 0) -> AXUIElement? {
        if d > 6 { return nil }
        if idStr(e) == "sm.strip" { return e }
        for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
            if let r = findStrip(c, d + 1) { return r }
        }
        return nil
    }
    var found = false
    if let strip = findStrip(app) {
        for el in (attr(strip, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
            let ids = (attr(el, "AXWindowsIDs") as? [NSNumber])?.map { $0.intValue }.sorted() ?? []
            if ids == want {
                let f = frameOf(el)
                let p = CGPoint(x: f.midX, y: f.midY)
                let src = CGEventSource(stateID: .hidSystemState)!
                CGWarpMouseCursorPosition(p)
                CGAssociateMouseAndMouseCursorPosition(1)
                usleep(30_000)
                for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
                    e?.post(tap: .cghidEventTap)
                    usleep(30_000)
                }
                print("clicked tile ids=\(ids) at \(Int(p.x)),\(Int(p.y))")
                found = true
            }
        }
    }
    if !found { print("no tile with ids \(want)"); exit(4) }
case "pressids":
    // r19ax pressids 399,434 — perform kAXPressAction on the stage tile whose AXWindowsIDs match
    // (works while the strip is retracted; no coordinates, so nothing can be behind it)
    let want = a[2].split(separator: ",").compactMap { Int($0) }.sorted()
    guard let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else {
        print("no WindowManager"); exit(3)
    }
    let app = AXUIElementCreateApplication(wm.processIdentifier)
    func idStr(_ e: AXUIElement) -> String { (attr(e, "AXIdentifier") as? String) ?? "" }
    func findStrip(_ e: AXUIElement, _ d: Int = 0) -> AXUIElement? {
        if d > 6 { return nil }
        if idStr(e) == "sm.strip" { return e }
        for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
            if let r = findStrip(c, d + 1) { return r }
        }
        return nil
    }
    var done = false
    if let strip = findStrip(app) {
        for el in (attr(strip, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
            let ids = (attr(el, "AXWindowsIDs") as? [NSNumber])?.map { $0.intValue }.sorted() ?? []
            if ids == want {
                let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
                print("press tile ids=\(ids) err=\(err.rawValue)")
                done = true
            }
        }
    }
    if !done { print("no tile with ids \(want)"); exit(4) }
case "frame":
    let cg = UInt32(a[2])!
    guard let it = all().first(where: { $0.cgid == cg }) else { print("no ax window cgid=\(cg)"); exit(3) }
    print("frame cgid=\(cg) \(Int(it.frame.origin.x)),\(Int(it.frame.origin.y)) \(Int(it.frame.width))x\(Int(it.frame.height))")
default:
    print("?")
}
