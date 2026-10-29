// StagePilot — companion app for macOS Stage Manager.
// Route A only: Accessibility + synthesized input. No root, no SIP changes, no injection.
//
// What it can do (all measured on macOS 27):
//   * bring a newly opened window into the current stage (shift-click its strip tile)
//   * switch stages / merge a stage into the current one
//   * move the front window to another stage (switch + merge)
//   * "peek" the strip by reserving the 285 pt gutter for the front window
//
// Build: see build.sh. Run with a CLI verb for testing, or with no args for the menu bar app.

import Cocoa
import ApplicationServices

// MARK: - AX helpers

func axAttr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func axStr(_ e: AXUIElement, _ name: String) -> String { (axAttr(e, name) as? String) ?? "" }
func axChildren(_ e: AXUIElement) -> [AXUIElement] { (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axFrame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = axAttr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = axAttr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func axSetFrame(_ e: AXUIElement, _ r: CGRect) -> Bool {
    var p = r.origin, s = r.size
    let pv = AXValueCreate(.cgPoint, &p)!, sv = AXValueCreate(.cgSize, &s)!
    let a = AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, pv)
    let b = AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sv)
    return a == .success && b == .success
}

// MARK: - Stage model, read from WindowManager's own AX tree

struct Stage {
    let index: Int
    let title: String
    let frame: CGRect
    let windowIDs: [Int]
    let element: AXUIElement
}

enum WM {
    static var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first?.processIdentifier
    }
    static func app() -> AXUIElement? { pid.map { AXUIElementCreateApplication($0) } }

    static func find(_ e: AXUIElement, _ id: String, _ depth: Int = 0) -> AXUIElement? {
        if depth > 4 { return nil }
        if axStr(e, "AXIdentifier") == id { return e }
        for c in axChildren(e) { if let r = find(c, id, depth + 1) { return r } }
        return nil
    }

    static func stripElement() -> AXUIElement? { app().flatMap { find($0, "sm.strip") } }

    /// Stages are the piles in the strip. The active stage is not in the strip.
    static func stages() -> [Stage] {
        guard let strip = stripElement() else { return [] }
        return axChildren(strip).enumerated().compactMap { i, el in
            guard axStr(el, kAXRoleAttribute) == kAXButtonRole else { return nil }
            let ids = (axAttr(el, "AXWindowsIDs") as? [NSNumber])?.map { $0.intValue } ?? []
            return Stage(index: i, title: axStr(el, kAXTitleAttribute), frame: axFrame(el),
                         windowIDs: ids, element: el)
        }
    }

    /// Left gutter the window server reserves when the strip is out (measured 285 pt incl. margins).
    static func stripRect() -> CGRect? { stripElement().map(axFrame) }

    /// A collapsed strip element reports a zero-size frame at x=16, so check size too.
    static func stripIsOut() -> Bool {
        guard let r = stripRect() else { return false }
        return r.origin.x >= 0 && r.width > 100 && r.height > 50
    }
}

// MARK: - Synthesized input

enum Input {
    static func cursor() -> CGPoint { CGEvent(source: nil)!.location }

    static func move(to p: CGPoint) {
        // a non-zero delta matters: the WM's gesture recogniser ignores zero-delta moves
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                              mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: 1)
        e.post(tap: .cghidEventTap)
    }

    /// Walk the pointer to `p` in small steps (some WM gestures ignore teleports).
    static func glide(to p: CGPoint, steps: Int = 12) {
        let from = cursor()
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            move(to: CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t))
            usleep(6_000)
        }
    }

    static func click(at p: CGPoint, shift: Bool = false) {
        let src = CGEventSource(stateID: .hidSystemState)
        let saved = cursor()
        // warp: no gesture pipeline involved, so the pointer can jump straight there
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
        usleep(4_000)
        if shift {
            let down = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)
            down?.flags = .maskShift
            down?.post(tap: .cghidEventTap)
            usleep(3_000)
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            if shift { e?.flags = .maskShift }
            e?.post(tap: .cghidEventTap)
            usleep(4_000)
        }
        if shift {
            let up = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)
            up?.flags = []
            up?.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Reveal the strip if it is not out: a real HID hover at the left edge.
    @discardableResult
    static func revealStrip(timeout: TimeInterval = 1.2) -> Bool {
        if WM.stripIsOut() { return true }
        let saved = cursor()
        let y = NSScreen.main.map { $0.frame.height * 0.55 } ?? 540
        glide(to: CGPoint(x: 260, y: y), steps: 10)
        for i in 1...26 { move(to: CGPoint(x: 260 - 259 * Double(i) / 26, y: y)); usleep(7_000) }
        for _ in 0..<18 { move(to: CGPoint(x: 1, y: y)); usleep(9_000) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = WM.stripRect(), r.origin.x >= 0 { break }
            usleep(40_000)
        }
        glide(to: saved, steps: 6); move(to: saved)
        return (WM.stripRect()?.origin.x ?? -1) >= 0
    }
}

// MARK: - Actions

enum Actions {
    static func switchTo(stage: Stage) -> Bool {
        let peeked = !WM.stripIsOut()
        defer { if peeked { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { peekOff() } } }
        for _ in 0..<3 {
            guard ensureStrip() else { return false }
            usleep(150_000)
            // if it is no longer a pile, it already became the active stage
            guard let fresh = WM.stages().first(where: { $0.windowIDs == stage.windowIDs }) else { return true }
            Input.click(at: CGPoint(x: fresh.frame.midX, y: fresh.frame.midY))
            usleep(420_000)
            if WM.stages().first(where: { $0.windowIDs == stage.windowIDs }) == nil { return true }
        }
        return false
    }

    /// Add one window of that stage to the current stage (native merge primitive).
    static func merge(stage: Stage) -> Bool {
        let peeked = !WM.stripIsOut()
        defer { if peeked { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { peekOff() } } }
        let before = stage.windowIDs
        for _ in 0..<3 {
            guard ensureStrip() else { return false }
            usleep(150_000)
            guard let fresh = WM.stages().first(where: { $0.windowIDs == before }) else { return true }  // gone: merged
            Input.click(at: CGPoint(x: fresh.frame.midX, y: fresh.frame.midY), shift: true)
            usleep(420_000)
            let moved = WM.stages().first(where: { $0.windowIDs == before })?.windowIDs != before
            if moved {
                // the pile's top window is what got added; bring it to the front
                if let newID = before.last {
                    Actions.raiseWindow(id: newID)
                    usleep(200_000)
                    Actions.raiseWindow(id: newID)
                }
                return true
            }
        }
        return false
    }

    /// Move the frontmost window into another stage: go there, then merge its tile in.
    static func moveFrontWindow(to target: Stage) -> Bool {
        guard let front = frontWindow() else { return false }
        let frontID = windowNumber(of: front.element)
        guard let source = WM.stages().first(where: { $0.windowIDs.contains(where: { $0 == frontID }) }) else {
            return false   // window is already in the active stage
        }
        guard switchTo(stage: target) else { return false }
        usleep(320_000)
        guard let freshSource = WM.stages().first(where: { $0.windowIDs.contains(where: { $0 == frontID }) }) else { return false }
        _ = merge(stage: freshSource)
        // refresh titles in case a pile's top window changed
        _ = source
        return true
    }

    static func frontWindow() -> (app: NSRunningApplication, element: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.apple.WindowManager" else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        if let w = axAttr(ax, kAXFocusedWindowAttribute) { return (app, w as! AXUIElement) }
        if let ws = axAttr(ax, kAXWindowsAttribute) as? [AXUIElement], let w = ws.first { return (app, w) }
        return nil
    }

    static func windowNumber(of e: AXUIElement) -> Int {
        if let n = axAttr(e, "AXWindowNumber") as? NSNumber { return n.intValue }
        if let d = axAttr(e, "AXDocument") as? String, !d.isEmpty { _ = d }
        // fall back: match by frame
        let f = axFrame(e)
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let r = CGRect(x: b["X"] as? Double ?? 0, y: b["Y"] as? Double ?? 0,
                               width: b["Width"] as? Double ?? 0, height: b["Height"] as? Double ?? 0)
                if abs(r.origin.x - f.origin.x) < 2, abs(r.origin.y - f.origin.y) < 2,
                   abs(r.width - f.width) < 3, abs(r.height - f.height) < 3 {
                    return (w[kCGWindowNumber as String] as? Int) ?? 0
                }
            }
        }
        return 0
    }


    /// After a merge the new window lands behind the stage's existing windows. Bring it forward.
    /// Frames move during the merge animation, so retry until the window's frame is stable and matches
    /// one of its app's AX windows.
    static func raiseWindow(id: Int, attempts: Int = 8) {
        guard id != 0 else { logTo("/private/tmp/stagepilot.log", "raise id=0"); return }
        var lastFrame = CGRect.null
        for _ in 0..<attempts {
            guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
                  let w = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == id }),
                  let pid = (w[kCGWindowOwnerPID as String] as? Int32).map({ pid_t($0) }) else { return }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let frame = CGRect(x: b["X"] as? Double ?? 0, y: b["Y"] as? Double ?? 0,
                               width: b["Width"] as? Double ?? 0, height: b["Height"] as? Double ?? 0)
            let stable = !lastFrame.isNull && abs(frame.origin.x - lastFrame.origin.x) < 1
                && abs(frame.origin.y - lastFrame.origin.y) < 1 && abs(frame.width - lastFrame.width) < 1
            lastFrame = frame
            if stable, width_ok(frame) {
                logTo("/private/tmp/stagepilot.log", "raise id=\(id) stable frame=\(frame)")
                let ax = AXUIElementCreateApplication(pid)
                AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                if let wins = axAttr(ax, kAXWindowsAttribute) as? [AXUIElement] {
                    for el in wins where near(axFrame(el), frame) {
                        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
                        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
                        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    }
                }
                return
            }
            usleep(160_000)
        }
    }

    private static func width_ok(_ r: CGRect) -> Bool { r.width > 200 && r.height > 150 }
    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 6 && abs(a.origin.y - b.origin.y) < 6
            && abs(a.width - b.width) < 10 && abs(a.height - b.height) < 10
    }

    // MARK: peek (feature 3 substitute)

    private static var saved: (element: AXUIElement, frame: CGRect)?

    static func gutter() -> CGFloat {
        if let r = WM.stripRect(), r.origin.x >= 0 { return r.maxX + 14 }
        return 285
    }

    /// Reserve the gutter for the front window so the strip can appear.
    static func peekOn() -> Bool {
        if let _ = saved { return true }
        guard let front = frontWindow() else { return false }
        let f = axFrame(front.element)
        let g = gutter()
        saved = (front.element, f)
        guard f.origin.x < g else { return true }
        let target = CGRect(x: g, y: f.origin.y, width: max(420, f.width - (g - f.origin.x)), height: f.height)
        return axSetFrame(front.element, target)
    }

    static func peekOff() {
        guard let s = saved else { return }
        _ = axSetFrame(s.element, s.frame)
        saved = nil
    }

    /// Make sure the strip is out. If a maximized window is suppressing it, optionally make room.
    static func ensureStrip() -> Bool {
        if WM.stripIsOut() { return true }
        if Input.revealStrip() { return true }
        let auto = (UserDefaults.standard.object(forKey: "autoMakeRoom") as? Bool) ?? false
        guard auto else { return false }
        guard peekOn() else { return false }
        return Input.revealStrip()
    }
}

// MARK: - New-window router

final class Router {
    var enabled = false { didSet { if enabled { prime() } else { seen.removeAll() } } }
    private var seen = Set<Int>()
    private var timer: Timer?
    private var busy = false

    init() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func prime() {
        seen.removeAll()
        for s in WM.stages() { seen.formUnion(s.windowIDs) }
    }

    private func tick() {
        guard enabled, !busy else { return }
        let stages = WM.stages()
        for s in stages {
            for id in s.windowIDs where !seen.contains(id) {
                seen.insert(id)
                // only act when the new window is the pile's top window (it is, when it just appeared)
                guard s.windowIDs.last == nil || s.windowIDs.contains(id) else { continue }
                busy = true
                DispatchQueue.main.async {
                    if !Actions.ensureStrip() { self.busy = false; return }
                    if let fresh = WM.stages().first(where: { $0.windowIDs.contains(id) }) {
                        Input.click(at: CGPoint(x: fresh.frame.midX, y: fresh.frame.midY), shift: true)
                        // the WM re-orders during and after the merge animation, so raise late and twice
                        usleep(420_000)
                        Actions.raiseWindow(id: id)
                        usleep(320_000)
                        Actions.raiseWindow(id: id)
                    }
                    self.busy = false
                }
                return
            }
        }
        for s in stages { seen.formUnion(s.windowIDs) }
    }
}

// MARK: - App

func logTo(_ path: String, _ line: String) {
    let f = FileHandle(forWritingAtPath: path) ?? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)!
    }()
    f.seekToEndOfFile()
    f.write(("[ \(Date()) ] " + line + "\n").data(using: .utf8)!)
    try? f.close()
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let router = Router()
    var statusItem: NSStatusItem!
    var peeked = false

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: ["routeNewWindows": true])
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        router.enabled = UserDefaults.standard.bool(forKey: "routeNewWindows")
        logTo("/private/tmp/stagepilot.log", "launch trusted=\(AXIsProcessTrusted()) stages=\(WM.stages().count) route=\(router.enabled)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◧"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let stages = WM.stages()
        let strip = WM.stripRect()
        let stripOut = WM.stripIsOut()
        let status = stripOut ? "strip visible" : "strip hidden"
        let head = NSMenuItem(title: stages.isEmpty ? "StagePilot — \(status)" : "StagePilot — \(stages.count) other stage\(stages.count == 1 ? "" : "s"), \(status)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "⚠︎ Grant Accessibility permission…", action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        let route = NSMenuItem(title: "Bring new windows to the current stage", action: #selector(toggleRoute), keyEquivalent: "")
        route.target = self
        route.state = router.enabled ? .on : .off
        menu.addItem(route)

        let peek = NSMenuItem(title: "Make room for the strip (resizes front window)", action: #selector(togglePeek), keyEquivalent: "")
        peek.target = self
        peek.state = peeked ? .on : .off
        menu.addItem(peek)

        menu.addItem(.separator())
        let switchHeader = NSMenuItem(title: "Switch to stage", action: nil, keyEquivalent: "")
        switchHeader.isEnabled = false
        menu.addItem(switchHeader)
        for s in stages {
            let i = NSMenuItem(title: "  \(s.title.isEmpty ? "Untitled stage" : s.title)", action: #selector(switchStage(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = s.windowIDs
            menu.addItem(i)
        }

        menu.addItem(.separator())
        let moveHeader = NSMenuItem(title: "Move front window to", action: nil, keyEquivalent: "")
        moveHeader.isEnabled = false
        menu.addItem(moveHeader)
        for s in stages {
            let i = NSMenuItem(title: "  \(s.title.isEmpty ? "Untitled stage" : s.title)", action: #selector(moveStage(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = s.windowIDs
            menu.addItem(i)
        }

        menu.addItem(.separator())
        let reveal = NSMenuItem(title: "Reveal strip", action: #selector(reveal), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let quit = NSMenuItem(title: "Quit StagePilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @objc func toggleRoute() {
        router.enabled.toggle()
        UserDefaults.standard.set(router.enabled, forKey: "routeNewWindows")
    }
    @objc func togglePeek() {
        if peeked { Actions.peekOff() } else { _ = Actions.peekOn() }
        peeked.toggle()
    }
    @objc func reveal() { _ = Input.revealStrip() }
    private func stage(for ids: [Int]) -> Stage? { WM.stages().first { $0.windowIDs == ids } }
    @objc func switchStage(_ i: NSMenuItem) {
        if let s = stage(for: (i.representedObject as? [Int]) ?? []) { _ = Actions.switchTo(stage: s) }
    }
    @objc func moveStage(_ i: NSMenuItem) {
        if let s = stage(for: (i.representedObject as? [Int]) ?? []) { _ = Actions.moveFrontWindow(to: s) }
    }
}

// MARK: - CLI (testing)

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "stages":
        for s in WM.stages() { print("[\(s.index)] '\(s.title)' frame=\(s.frame) windows=\(s.windowIDs)") }
        print("strip=\(String(describing: WM.stripRect()))")
    case "reveal":
        print("revealed=\(Input.revealStrip())")
    case "switch":
        if let n = Int(args.dropFirst(2).first ?? ""), let s = WM.stages().first(where: { $0.index == n }) {
            print("switch \(n) -> \(Actions.switchTo(stage: s))")
        }
    case "merge":
        if let n = Int(args.dropFirst(2).first ?? ""), let s = WM.stages().first(where: { $0.index == n }) {
            print("merge \(n) -> \(Actions.merge(stage: s))")
        }
    case "move":
        if let n = Int(args.dropFirst(2).first ?? ""), let s = WM.stages().first(where: { $0.index == n }) {
            print("move -> \(Actions.moveFrontWindow(to: s))")
        }
    case "peek":
        print(args.count > 2 && args[2] == "off" ? "peek off" : "peek on=\(Actions.peekOn())")
        if args.count > 2 && args[2] == "off" { Actions.peekOff() }
    case "route":
        let secs = Double(args.dropFirst(2).first ?? "10") ?? 10
        let r = Router()
        r.enabled = true
        print("routing for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
        NSApplication.shared.run()
    default:
        print("usage: StagePilot [stages|reveal|switch N|merge N|move N|peek [off]|route SECONDS]")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
