// wmobs — user-side observer for the consolidated control surface.
// Publishes, every 20 ms, what a root debug session cannot see:
//   /tmp/wm/obs.log      NEW / FULL / TILE events with epoch timestamps (same clock as wm.py)
//   /tmp/wm/pending.txt  every non-system window seen in the last 10 s ("<cgid> <owner>")
// Same program as round 18's r18obs, pointed at /tmp/wm.
import Foundation
import CoreGraphics

let D = "/tmp/wm"
let EV = D + "/obs.log"
let PENDING = D + "/pending.txt"
let POLL: useconds_t = 20_000

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
log("OBS start pid=\(getpid())")
var lastPending = 0.0

while true {
    let t = Date().timeIntervalSince1970
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
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
    if t - lastPending > 0.05 {
        lastPending = t
        let recent = seen.filter { t - $0.value.t0 < 10.0 && !SYSTEM.contains($0.value.owner) }
            .sorted { $0.value.t0 > $1.value.t0 }
        var txt = ""
        for (wid, s) in recent { txt += "\(wid) \(s.owner)\n" }
        let tmp = PENDING + ".tmp"
        try? txt.write(toFile: tmp, atomically: false, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: PENDING)
        try? FileManager.default.moveItem(atPath: tmp, toPath: PENDING)
    }
    usleep(POLL)
}
