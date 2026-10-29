// wmobs — user-side observer for the consolidated control surface.
//
// It publishes what a root debug session cannot see:
//   /tmp/wm/obs.log      NEW / FULL / TILE events with epoch timestamps (same clock as wm.py)
//   /tmp/wm/pending.txt  every non-system window seen in the last 10 s ("<cgid> <owner>")
//
// This used to be a 20 ms `CGWindowListCopyWindowInfo` loop.  A window list scan is expensive
// (measured 13% of one core idle) and the only thing it can learn is "something appeared"; the
// window server already knows.  This build registers for its connection notifications (resolved
// by name from SkyLight, the same image the keeper symbols come from), coalesces any number of
// them into one dirty flag, and re-reads the list once per run-loop turn.  The birth path reads
// the NEW lines, so a creation notification is the event it needs and it now arrives sooner than
// the old 20 ms poll could deliver it.
//
// usage: wmobs [--debug]
import Cocoa
import CoreGraphics
import Darwin

let D = "/tmp/wm"
let EV = D + "/obs.log"
let PENDING = D + "/pending.txt"
let DEBUG = CommandLine.arguments.contains("--debug")

func log(_ s: String) {
    let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, s)
    if let h = FileHandle(forWritingAtPath: EV) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: EV, contents: line.data(using: .utf8))
    }
}

let SYSTEM: Set<String> = ["Window Server", "WindowManager", "Dock", "Control Center",
    "ControlCenter", "CursorUIViewService", "AutoFill", "Open and Save Panel Service",
    "Notification Center", "Spotlight", "Siri", "SystemUIServer", "Universal Control",
    "TextInputMenuAgent", "loginwindow", "WeatherMenu", "SecurityAgent"]

struct Seen {
    var t0: Double
    var owner: String
    var pid: Int
    var name: String
    var full: Double = 0
    var tile: Double = 0
    var big: Bool = false
    var firstX: Double
    var firstY: Double
    var firstW: Double
    var firstH: Double
}

var seen: [Int: Seen] = [:]
try? FileManager.default.createDirectory(atPath: D, withIntermediateDirectories: true)

// ---------------------------------------------------------------- SkyLight notifications
typealias ConnCB = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let slMain = sl.flatMap { dlsym($0, "SLSMainConnectionID") }
let slReg = sl.flatMap { dlsym($0, "SLSRegisterConnectionNotifyProc") }
let slReq = sl.flatMap { dlsym($0, "SLSRequestNotificationsForWindows") }
let cid = slMain.map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self)() } ?? 0

var dirty = false
var scheduled = false

func schedule() {
    dirty = true
    if scheduled { return }
    scheduled = true
    DispatchQueue.main.async {
        scheduled = false
        while dirty { dirty = false; scan() }
    }
}

let eventCB: ConnCB = { _, _, _, _, _ in schedule() }

var subscribed = Set<Int>()
var lastPending = ""

func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
}

func subscribe(_ ws: [[String: Any]]) {
    guard let f = slReq else { return }
    let fn = unsafeBitCast(f, to: (@convention(c) (Int32, UnsafeMutablePointer<UInt32>?, Int32) -> Int32).self)
    var fresh: [UInt32] = []
    for w in ws {
        guard let n = w[kCGWindowNumber as String] as? Int, n > 0, !subscribed.contains(n) else { continue }
        subscribed.insert(n)
        fresh.append(UInt32(n))
    }
    if !fresh.isEmpty { _ = fresh.withUnsafeMutableBufferPointer { fn(cid, $0.baseAddress, Int32($0.count)) } }
}

func scan() {
    let t = Date().timeIntervalSince1970
    let list = windows()
    subscribe(list)
    for w in list {
        let layer = w[kCGWindowLayer as String] as? Int ?? -9
        if layer > 10 { continue }
        guard let wid = w[kCGWindowNumber as String] as? Int else { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
        let name = w[kCGWindowName as String] as? String ?? ""
        let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
        let bw = b["Width"] as? Double ?? 0, bh = b["Height"] as? Double ?? 0
        var s: Seen
        if let e = seen[wid] {
            s = e
        } else {
            s = Seen(t0: t, owner: owner, pid: pid, name: name,
                     firstX: x, firstY: y, firstW: bw, firstH: bh)
            seen[wid] = s
            log(String(format: "NEW wid=%d owner=%@ pid=%d on=%@ %.0f,%.0f %.0fx%.0f name=%@",
                       wid, owner, pid, on ? "1" : "0", x, y, bw, bh, name))
        }
        if !s.big && bw >= 60 && bh >= 60 && !SYSTEM.contains(owner) && layer == 0 {
            s.big = true; seen[wid] = s
        }
        if on && s.full == 0 && x >= 200 && bw >= 300 && bh >= 250 {
            s.full = t; seen[wid] = s
            log(String(format: "FULL wid=%d owner=%@ dt=%.3f at %.0f,%.0f %.0fx%.0f",
                       wid, owner, t - s.t0, x, y, bw, bh))
        }
        if on && s.tile == 0 && x < 260 && bw <= 260 && bh <= 260 {
            s.tile = t; seen[wid] = s
            log(String(format: "TILE wid=%d owner=%@ dt=%.3f at %.0f,%.0f %.0fx%.0f",
                       wid, owner, t - s.t0, x, y, bw, bh))
        }
    }
    // Window ids are never reused, so an entry leaves `pending` when a newer read no longer shows
    // it or when it ages past 10 s.  The age test runs on every read, which is an event here, so
    // there is no timer to expire it.
    var txt = ""
    let recent = seen.filter { t - $0.value.t0 < 10.0 && !SYSTEM.contains($0.value.owner) }
        .sorted { $0.value.t0 > $1.value.t0 }
    for (wid, s) in recent { txt += "\(wid) \(s.owner)\n" }
    if txt != lastPending {
        lastPending = txt
        let tmp = PENDING + ".tmp"
        try? txt.write(toFile: tmp, atomically: false, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: PENDING)
        try? FileManager.default.moveItem(atPath: tmp, toPath: PENDING)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

log("OBS start pid=\(getpid())")

if let f = slReg {
    let fn = unsafeBitCast(f, to: (@convention(c) (Int32, ConnCB?, UInt32, UnsafeMutableRawPointer?) -> Int32).self)
    for e in [UInt32(804), 806, 807, 808, 811, 815, 816, 1202, 1204, 1325, 1327, 1328] {
        _ = fn(cid, eventCB, e, nil)
    }
}

CGDisplayRegisterReconfigurationCallback({ _, _, _ in schedule() }, nil)
let wc = NSWorkspace.shared.notificationCenter
for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
             NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
             NSWorkspace.didUnhideApplicationNotification] {
    wc.addObserver(forName: name, object: nil, queue: .main) { _ in schedule() }
}

scan()
app.run()
