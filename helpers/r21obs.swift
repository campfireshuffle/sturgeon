import Cocoa
import Foundation
import CoreGraphics
import Darwin

// r21obs — out-of-process observer for the state document the keeper gates on.
//
// It used to re-read CGWindowList every 25 ms and republish unconditionally.  The document is a
// *snapshot*, so a timer is the wrong trigger: the only thing a re-read can learn is "something
// moved".  This build is driven by the window server instead:
//
//   * SkyLight connection notifications (resolved by name from the framework, the same image the
//     keeper's symbols come from): window created / destroyed / ordered, space changes.  These are
//     hints, not state - the handler sets a dirty flag and one coalesced re-read publishes the
//     authoritative CGWindowList document through the same file the helper copies into the
//     payload's seqlock.
//   * display reconfiguration and NSWorkspace app launch/terminate/activate/hide.
//   * one request file: the payload's keeper asks the helper for a fresh document (see wmhb.c) and
//     the helper writes here; a kqueue vnode watch turns that into a re-read.  This is the
//     lost-event defence - a dropped notification costs one keeper call, not a stale session.
//
// Measured on this build: moves, resizes and transform writes produce *no* connection
// notification (see docs/TECHNICAL.md), so a pure event model cannot see a strip animation frame.
// That is acceptable by construction: an animation is a transform on an already-drawn tile, so it
// changes none of the facts this document carries (membership, bounds, front window).  Every fact
// it does carry changes with an ordering event.
//
// usage: r21obs [--out /tmp/r21/wm/state.json] [--rail 320] [--minw 1200] [--debug]

setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
func opt(_ n: String, _ d: String) -> String {
    if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }
    return d
}
let OUT = opt("--out", "/tmp/r21/state.json")
let RAIL = Double(opt("--rail", "320"))!
let MINW = Double(opt("--minw", "1200"))!
let DEBUG = args.contains("--debug")
let REQ = (OUT as NSString).deletingLastPathComponent + "/state.req"
let ACK = (OUT as NSString).deletingLastPathComponent + "/state.ack"

func note(_ s: String) {
    guard DEBUG else { return }
    FileHandle.standardError.write("\(String(format: "%.3f", Date().timeIntervalSince1970)) \(s)\n".data(using: .utf8)!)
}

let skip: Set<String> = ["WindowManager", "Window Server", "Dock", "Control Center", "Notification Center",
                         "CursorUIViewService", "Wallpaper", "Spotlight", "TextInputMenuAgent",
                         "SystemUIServer", "loginwindow", "SecurityAgent"]

// ---------------------------------------------------------------- SkyLight notifications
typealias ConnCB = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
let slHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let slMain = slHandle.flatMap { dlsym($0, "SLSMainConnectionID") }
let slReg = slHandle.flatMap { dlsym($0, "SLSRegisterConnectionNotifyProc") }
let slReq = slHandle.flatMap { dlsym($0, "SLSRequestNotificationsForWindows") }
let cid = slMain.map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self)() } ?? 0

var dirty = false
var scheduled = false
var pendingReq: String? = nil
var ackedReq = ""
// Test hook for the issue's "dropped notification" trial: ignore the next N window-server
// notifications.  It is a synthetic lost event, not a mode: it self-clears and only the event
// handler consults it.  Nothing in the publish path knows it exists.
var dropN = Int(ProcessInfo.processInfo.environment["R21OBS_DROP_N"] ?? "0") ?? 0
// The same trial with a deterministic trigger: while this path exists, every window-server
// notification is ignored.  One file stat per event, only when the variable is set.
let dropFile = ProcessInfo.processInfo.environment["R21OBS_DROP_FILE"]

// One published document per run-loop turn, however many notifications arrived.  A duplicate or
// coalesced event costs nothing; the read below is the only source of truth.
func schedule(_ why: String) {
    dirty = true
    if scheduled { return }
    scheduled = true
    DispatchQueue.main.async {
        scheduled = false
        while dirty {
            dirty = false
            refresh()
        }
        // A keeper request is acknowledged only after the re-read it asked for has published.
        // The ack is written even when the document did not change: "no change" is an answer, and
        // the helper must be able to mark the request served either way.
        if let r = pendingReq, r != ackedReq {
            pendingReq = nil
            try? (r + "\n").write(toFile: ACK, atomically: false, encoding: .utf8)
            ackedReq = r
            note("req \(r) served")
        }
    }
    _ = why
}

let eventCB: ConnCB = { type, _, _, _, _ in
    if DEBUG { note("event \(type)") }
    if dropN > 0 { dropN -= 1; note("DROPPED event \(type)"); return }
    if let f = dropFile, FileManager.default.fileExists(atPath: f) {
        note("DROPPED event \(type) (flag)")
        return
    }
    schedule("sls")
}

var subscribed = Set<Int>()
var known: [Int: Double] = [:]
var seenOwner: [Int: String] = [:]
var lastKey: String? = nil
var published = 0

func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
}
func frameOf(_ w: [String: Any]) -> CGRect {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return CGRect(x: b["X"] as? Double ?? 0, y: b["Y"] as? Double ?? 0,
                  width: b["Width"] as? Double ?? 0, height: b["Height"] as? Double ?? 0)
}

// Ask for per-window notifications for every window we have not subscribed to yet.  Ordering and
// destruction are delivered per window; without this the connection only reports our own.
func subscribe(_ ws: [[String: Any]]) {
    guard let f = slReq else { return }
    let fn = unsafeBitCast(f, to: (@convention(c) (Int32, UnsafeMutablePointer<UInt32>?, Int32) -> Int32).self)
    var fresh: [UInt32] = []
    for w in ws {
        guard let n = w[kCGWindowNumber as String] as? Int, n > 0, !subscribed.contains(n) else { continue }
        subscribed.insert(n)
        fresh.append(UInt32(n))
    }
    guard !fresh.isEmpty else { return }
    _ = fresh.withUnsafeMutableBufferPointer { fn(cid, $0.baseAddress, Int32($0.count)) }
    note("subscribed +\(fresh.count) (total \(subscribed.count))")
}

func refresh() {
    let ws = windows()
    subscribe(ws)
    let now = Date().timeIntervalSince(date0)
    var front: (String, CGRect)? = nil
    var rail: [Int] = []
    var rails: [[String: Any]] = []
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
    // Idempotent: compare the *facts*, not the serialised object (which carries `t`).  Publishing
    // an identical snapshot is pure wakeup cost for the helper that copies it, and the design's
    // whole point is that replaying an event costs nothing.
    var key = "\(flush)|\(stripOn)|\(onCount)|\(Int(frontX))|\(fr)|"
    for i in ids.sorted() { key += "\(i)," }
    key += "|"
    for r in rails { key += "\(r["id"]!):\(r["x"]!):\(r["y"]!):\(r["w"]!):\(r["h"]!):\(r["on"]!)," }
    key += "|"
    for i in railNow.sorted() { key += "\(i)," }
    if let last = lastKey, last == key { return }
    lastKey = key
    let obj: [String: Any] = ["flush": flush, "strip_ids": ids.sorted(),
                              "rail_now": railNow.sorted(), "front": fr,
                              "strip_on": stripOn, "rail_on": onCount, "front_x": frontX,
                              "rail": rails, "t": Date().timeIntervalSince1970]
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
    let tmp = OUT + ".tmp"
    do {
        try d.write(to: URL(fileURLWithPath: tmp))
        _ = try? FileManager.default.removeItem(atPath: OUT)
        try FileManager.default.moveItem(atPath: tmp, toPath: OUT)
        published += 1
        note("published #\(published) rail_now=\(railNow.count) strip_on=\(stripOn ? 1 : 0) front_x=\(Int(frontX))")
    } catch {
        note("write failed \(error)")
    }
}

// ---------------------------------------------------------------- request channel (keeper nudge)
// wmhb writes the payload's request counter here when the keeper asks for a document.  A vnode
// watch means a request is one wakeup, not a poll.  The file is created here so the watch exists
// before the first request, and the inode never changes (the helper truncates in place).
var reqFD: Int32 = -1
var kq: Int32 = -1
func startReqWatch() {
    let dir = (OUT as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for f in [REQ, ACK] where !FileManager.default.fileExists(atPath: f) {
        FileManager.default.createFile(atPath: f, contents: Data())
    }
    reqFD = open(REQ, O_EVTONLY)
    guard reqFD >= 0 else { note("req watch: open failed"); return }
    kq = kqueue()
    guard kq >= 0 else { note("req watch: kqueue failed"); return }
    var ev = kevent()
    ev.ident = UInt(reqFD)
    ev.filter = Int16(EVFILT_VNODE)
    ev.flags = UInt16(EV_ADD | EV_CLEAR)
    ev.fflags = UInt32(NOTE_WRITE | NOTE_EXTEND)
    ev.udata = nil
    var none = timespec()
    _ = kevent(kq, &ev, 1, nil, 0, &none)
    DispatchQueue.global(qos: .userInitiated).async {
        var e = kevent()
        while true {
            // nil timeout: block until the helper touches the request file.  This thread is the
            // only waiter, so a blocking kevent is the whole cost of the channel.
            let n = kevent(kq, nil, 0, &e, 1, nil)
            if n > 0 {
                let id = ((try? String(contentsOfFile: REQ, encoding: .utf8)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, id != ackedReq else { continue }
                DispatchQueue.main.async { pendingReq = id }
                schedule("req")
            }
        }
    }
}

// ---------------------------------------------------------------- lifecycle
let date0 = Date()
try? FileManager.default.createDirectory(atPath: (OUT as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
note("OBS start pid=\(getpid()) cid=\(cid) out=\(OUT)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if let f = slReg {
    let fn = unsafeBitCast(f, to: (@convention(c) (Int32, ConnCB?, UInt32, UnsafeMutableRawPointer?) -> Int32).self)
    // 804 destroyed, 806/807/815/816 window/session classes (they also fire at a low rate while
    // the session is busy - a free consistency net), 808 ordered, 811 created, 1325/1327/1328
    // space + animation-group, 1202/1204 cmd-tab / mission control.  Every one is only a hint.
    for e in [UInt32(804), 806, 807, 808, 811, 815, 816, 1202, 1204, 1325, 1327, 1328] {
        _ = fn(cid, eventCB, e, nil)
    }
    note("registered \(12) connection classes")
} else {
    note("SkyLight notification symbols unavailable")
}

CGDisplayRegisterReconfigurationCallback({ _, _, _ in schedule("display") }, nil)

let wc = NSWorkspace.shared.notificationCenter
for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
             NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
             NSWorkspace.didUnhideApplicationNotification] {
    wc.addObserver(forName: name, object: nil, queue: .main) { _ in schedule("workspace") }
}

startReqWatch()
subscribe(windows())
refresh()

app.run()
