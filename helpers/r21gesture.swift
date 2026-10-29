import Cocoa
import Foundation

// r21gesture — the strip-resize trigger.
//
// Receives, globally:
//   * magnify (trackpad pinch)            -> s *= (1 + magnification)          [preferred]
//   * scroll with Option held             -> s += 0.05 per notch              [fallback]
//   * Ctrl+Option+Up / Ctrl+Option+Down   -> s += / -= 0.1                    [fallback]
//
// and publishes {"enabled":true,"replay":true,"s":<scale>,"qx":16,"qy":490,"gen":N}
// to /tmp/r21/cfg.json.  The in-WM agent (r21agent.sh) picks up the new `gen`, interrupts
// WindowManager, commits the dilated poses through the WM's own SkyLight connection, resumes.
//
// usage: r21gesture [--step 0.05] [--min 0.4] [--max 1.6] [--out /tmp/r21/cfg.json]

setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let args = CommandLine.arguments
func opt(_ n: String, _ d: String) -> String {
    if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }
    return d
}
let STEP = Double(opt("--step", "0.05"))!
let MIN = Double(opt("--min", "0.4"))!
let MAX = Double(opt("--max", "1.5"))!
let OUT = opt("--out", "/tmp/r21/cfg.json")
let LOG = "/tmp/r21/gesture.log"
let QX = 16.0, QY = 490.0

var scale = 1.0
var gen = 1000
var lastWrite = Date(timeIntervalSince1970: 0)

func log(_ s: String) {
    let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, s)
    if let h = FileHandle(forWritingAtPath: LOG) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: LOG, contents: line.data(using: .utf8))
    }
}

func clamp(_ v: Double) -> Double { max(MIN, min(MAX, v)) }

func publish(_ why: String) {
    scale = clamp(scale)
    gen += 1
    let obj: [String: Any] = ["enabled": true, "replay": true, "s": scale,
                              "qx": QX, "qy": QY, "gen": gen]
    if let d = try? JSONSerialization.data(withJSONObject: obj) {
        let tmp = OUT + ".tmp"
        try? d.write(to: URL(fileURLWithPath: tmp))
        try? FileManager.default.removeItem(atPath: OUT)
        try? FileManager.default.moveItem(atPath: tmp, toPath: OUT)
    }
    log(String(format: "%@ s=%.3f gen=%d", why, scale, gen))
    print(String(format: "%@ s=%.3f gen=%d", why, scale, gen))
}

func throttled(_ why: String, _ delta: @escaping () -> Void) {
    let now = Date()
    if now.timeIntervalSince(lastWrite) < 0.03 { return }
    lastWrite = now
    delta()
    publish(why)
}

// ---------- pinch (magnify)
let mag = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { e in
    throttled("pinch", { scale *= (1.0 + e.magnification) })
}
if mag == nil { log("NO magnify global monitor") } else { log("magnify monitor installed") }

// ---------- scroll + Option
let scroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { e in
    guard e.modifierFlags.contains(.option) else { return }
    let d = e.hasPreciseScrollingDeltas ? -e.scrollingDeltaY * 0.002 : -e.scrollingDeltaY * STEP
    throttled("scroll", { scale += d })
}
if scroll == nil { log("NO scroll global monitor") } else { log("scroll monitor installed") }

// ---------- hotkey fallback (global key monitor)
let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
    guard e.modifierFlags.contains(.control), e.modifierFlags.contains(.option) else { return }
    if e.keyCode == 126 { throttled("hotkey+", { scale += 0.1 }) }       // Ctrl+Opt+Up
    if e.keyCode == 125 { throttled("hotkey-", { scale -= 0.1 }) }       // Ctrl+Opt+Down
}
if keys == nil { log("NO key global monitor") } else { log("key monitor installed") }

log("ready")
app.run()
