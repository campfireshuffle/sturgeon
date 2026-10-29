#!/usr/bin/python3
"""proof-round3.py — the armed evidence for the payload hardening round: issues #3, #4 and #31.

What it does, in order, and prints as JSON:

  pivot      teach at 1.0, `resize 1.5`, `resize 1.0`; per-tile ratio, the tile's own frame at
             1.5, the x/y it came back to, and the pivot that the frames *prove* was used
             (`p = x + (x - x15) / (s - 1)` — the point that did not move).
  constant   the same with `pivot_fixed` pinned to (16, 490), i.e. the old shipped constant, so
             the derived pivot can be compared against it on this display.
  trace      `trace=true`, one hover sweep, `wmship.sh trace`; record count, a sample, and the
             size bound.  Then `trace=false` and the same sweep again.
  stale      spawn a window that joins the current stage, teach, close it (the tile set shrinks
             *in place* — no hide), then `resize 1.5`: every remaining tile must scale.  This is
             the trial for the stale-base failure mode; `NO_RAILCHG=1` builds the negative
             control, where the stale base survives.

Usage:
    tools/proof-round3.py [--out DIR] [--phases pivot,constant,trace,stale] [--no-stop]

Preconditions, enforced: the shared machine lock named by `WMTEST_LOCK` is held by the caller,
the tool is DISARMED, and no debugger is running.  The script arms, and always disarms at the end
unless --no-stop is given (only for a deliberate A/B where the caller reinstalls immediately).
It never runs two bursts concurrently.

Environment:
    WMTEST_LOCK   path of the lock directory other sessions also honour (required)
    R20WIN        a test-window program that Stage Manager lays out as a strip tile, used by the
                  stale-base phase (optional; that phase is skipped without it)
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)
for p in (ROOT, os.path.join(ROOT, "wmship"), os.path.join(ROOT, "wm")):
    if p not in sys.path:
        sys.path.insert(0, p)
import ctl as C                                             # noqa: E402

LOCK = os.environ.get("WMTEST_LOCK", "")
R20WIN = os.environ.get("R20WIN", "")
STATE_JSON = "/tmp/wm/state.json"
S = os.path.join(ROOT, "wmship.sh")


def sh(args, timeout=300):
    r = subprocess.run([S] + args, capture_output=True, text=True, timeout=timeout)
    return {"rc": r.returncode, "out": r.stdout, "err": r.stderr}


def jout(res):
    """The first JSON value in a command's stdout (some verbs print a note after it)."""
    s = res.get("out", "")
    i = s.find("{")
    if i < 0:
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(s[i:])
        return obj
    except Exception:
        return None


def armed():
    out = sh(["status"], 120)["out"]
    return "ARMED" in out and "DISARMED" not in out


def doc():
    try:
        with open(STATE_JSON) as f:
            return json.load(f)
    except Exception:
        return {}


def reveal(timeout=20.0):
    """Make sure the strip is drawn: nudge the pointer onto the gutter once, then wait."""
    M = C.wmctl()
    t0 = time.time()
    nudged = False
    while time.time() - t0 < timeout:
        d = doc()
        if d.get("strip_on") and d.get("rail_now"):
            return d
        if not nudged:
            M.sh("%s 700 500 1 500 12" % M.MOVE)
            nudged = True
        time.sleep(0.3)
    return doc()


def frames():
    return {str(t["id"]): {"x": t["x"], "y": t["y"], "w": t["w"], "h": t["h"]}
            for t in C.rail_tiles()}


def hb():
    return C.hb()


def merge_cfg(**kw):
    """Exactly the app's write path: read the document, merge, write it back
    (`wmship.sh cfg '<json>'` -> install.py cfg, which also bumps the page generation)."""
    cur = None
    for _ in range(3):
        r = sh(["cfg"], 120)
        cur = jout(r)
        if isinstance(cur, dict):
            break
        time.sleep(0.3)
    if not isinstance(cur, dict):
        raise SystemExit("could not read the payload cfg: %r" % (r,))
    cur.update(kw)
    cur["gen"] = int(time.time() * 1000) & 0x7FFFFFFF
    w = sh(["cfg", json.dumps(cur)], 120)
    if w["rc"] != 0:
        raise SystemExit("cfg write failed: %r" % (w,))
    time.sleep(0.35)
    return w


def pivot_from(f0, f1, s):
    """The pivot the frames prove was used: the fixed point of the scale in screen coordinates."""
    out = []
    for k, a in f0.items():
        b = f1.get(k)
        if not b:
            continue
        qx = a["x"] + (a["x"] - b["x"]) / (s - 1.0)
        qy = a["y"] + (a["y"] - b["y"]) / (s - 1.0)
        out.append({"id": int(k), "qx": round(qx, 1), "qy": round(qy, 1)})
    return out


def resize(s):
    return jout(sh(["resize", str(s)], 600)) or {}


def ratios(rep):
    return {str(t["id"]): t.get("ratio") for t in (rep.get("tiles") or [])}


# ---------------------------------------------------------------- phases
def phase_pivot(rep, s=1.5):
    reveal()
    teach = {}
    for _ in range(3):                       # a single tile can miss its settle on a loaded machine
        teach = jout(sh(["teach"], 300)) or {}
        if teach.get("ok"):
            break
        time.sleep(1.0)
    rep["teach"] = teach
    if not teach.get("ok"):
        raise SystemExit("teach failed, cannot measure the pivot: %r" % (teach,))
    f0 = frames()
    r15 = resize(s)
    f15 = frames()
    h15 = hb()
    r10 = resize(1.0)
    f10 = frames()
    h10 = hb()
    rep["pivot"] = {
        "s": s,
        "resize_1.5": {"ok": r15.get("ok"), "ratios": ratios(r15), "xy": r15.get("xy")},
        "resize_1.0": {"ok": r10.get("ok"), "ratios": ratios(r10), "xy": r10.get("xy")},
        "pivot_reported_at_1.5": {"px": h15.get("px"), "py": h15.get("py"),
                                  "psrc": h15.get("psrc")},
        "pivot_proved_by_frames": pivot_from(f0, f15, s),
        "restore": {k: {ax: round(f10[k][ax] - f0[k][ax], 1) for ax in ("x", "y", "w", "h")}
                    for k in f0 if k in f10},
    }


def phase_constant(rep, s=1.5, qx=16.0, qy=490.0):
    merge_cfg(pivot_fixed=True, qx=qx, qy=qy)
    reveal()
    f0 = frames()
    r15 = resize(s)
    f15 = frames()
    h15 = hb()
    r10 = resize(1.0)
    f10 = frames()
    merge_cfg(pivot_fixed=False)
    rep["constant_pivot"] = {
        "pivot": [qx, qy],
        "resize_1.5": {"ok": r15.get("ok"), "ratios": ratios(r15)},
        "pivot_reported_at_1.5": {"px": h15.get("px"), "py": h15.get("py"),
                                  "psrc": h15.get("psrc")},
        "pivot_proved_by_frames": pivot_from(f0, f15, s),
        "restore": {k: {ax: round(f10[k][ax] - f0[k][ax], 1) for ax in ("x", "y", "w", "h")}
                    for k in f0 if k in f10},
    }


def phase_trace(rep):
    reveal()
    merge_cfg(trace=True)
    hb0 = hb()
    C.wmctl().force_writes(passes=1)
    time.sleep(1.0)
    tr_on = sh(["trace"], 180)["out"].splitlines()
    hb1 = hb()
    merge_cfg(trace=False)
    C.wmctl().force_writes(passes=1)
    time.sleep(1.0)
    tr_off = sh(["trace"], 180)["out"].splitlines()
    hb2 = hb()
    rep["trace"] = {
        "records_with_trace_on": len(tr_on),
        "records_after_trace_off": len(tr_off) - len(tr_on),
        "sample_first": tr_on[:3],
        "sample_last": tr_on[-3:],
        "max_record_bytes": max((len(x) for x in tr_on), default=0),
        "bases_before": hb0.get("bases"), "bases_after": hb1.get("bases"),
        "decisions_unchanged_when_off": (hb1.get("bases") == hb2.get("bases")),
    }


def spawn_tile(title):
    """A test window that Stage Manager *does* lay out as a strip tile.

    A plain AppKit binary launched from this root script does not join the stage (measured: the
    window never reaches `rail_now`).  The round-20 test window does, and it is what earlier rounds
    used as a subject.  It is copied to a unique name so its tile can be identified by owner even
    when other test windows of the same program are on the machine."""
    import shutil
    if not R20WIN:
        raise SystemExit("set R20WIN to a test-window program for the stale-base phase")
    exe = "/tmp/%s" % title
    shutil.copy(R20WIN, exe)
    os.chmod(exe, 0o755)
    log = "/tmp/%s.log" % title
    p = subprocess.Popen(["/bin/launchctl", "asuser", "501", "/usr/bin/sudo", "-u",
                          os.environ.get("SUDO_USER") or os.environ.get("USER", "root"), exe,
                          "--x", "221", "--y", "33", "--w", "700", "--h", "500",
                          "--title", title, "--log", log],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # r20win prints "READY pid=… cgid=N frame=…": the CGWindowID *is* the strip tile id, so the
    # trial knows which tile is its own without guessing from owners or id ranges.
    cgid = None
    t0 = time.time()
    while time.time() - t0 < 15 and cgid is None:
        try:
            txt = open(log).read()
        except Exception:
            txt = ""
        for line in txt.splitlines():
            if line.startswith("READY") and "cgid=" in line:
                cgid = int(line.split("cgid=")[1].split()[0])
                break
        time.sleep(0.3)
    return p, cgid


def kill_tile(p, title):
    subprocess.run(["/usr/bin/pkill", "-f", "--", title], capture_output=True)
    try:
        p.wait(timeout=10)
    except Exception:
        try:
            p.kill()
        except Exception:
            pass


def wait_hb(pred, timeout=20.0):
    t0 = time.time()
    h = hb()
    while time.time() - t0 < timeout:
        h = hb()
        if pred(h):
            return h
        time.sleep(0.25)
    return h


AXSET_SRC = r"""
import Cocoa
import ApplicationServices
let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: axwin <owner|-> frame x y w h | full 0|1"); exit(2) }
let owner = a[1]
func appFor(_ name: String) -> NSRunningApplication? {
    if name != "-", let a = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == name }) { return a }
    return NSWorkspace.shared.frontmostApplication
}
guard let app = appFor(owner) else { print("noapp"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
var ref: CFTypeRef?
var win: AXUIElement? = nil
if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &ref) == .success,
   let r = ref { win = (r as! AXUIElement) }
if win == nil {
    var wr: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &wr) == .success,
       let arr = wr as? [AXUIElement] { win = arr.first }
}
guard let w = win else { print("nowin"); exit(1) }
if a[2] == "front" {
    let e = AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    print("front err=\(e.rawValue)")
    exit(0)
}
if a[2] == "full" {
    let on = a[3] == "1"
    let e = AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString,
                                         (on ? kCFBooleanTrue : kCFBooleanFalse))
    usleep(300_000)
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &v)
    print("full=\((v as? Bool) == true ? 1 : 0) err=\(e.rawValue)")
    exit(0)
}
var x = Double(a[3])!, y = Double(a[4])!, ww = Double(a[5])!, hh = Double(a[6])!
if ww <= 0 || hh <= 0, let scr = NSScreen.main {   // -1: fill the main screen
    x = 0; y = 0; ww = scr.frame.width; hh = scr.frame.height
}
var pt = CGPoint(x: x, y: y); var sz = CGSize(width: ww, height: hh)
AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString,
                             AXValueCreate(.cgPoint, &pt)!)
AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString,
                             AXValueCreate(.cgSize, &sz)!)
var pv: CFTypeRef?, sv: CFTypeRef?
var p = CGPoint.zero; var s = CGSize.zero
if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success {
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
}
if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success {
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
}
print("\(Int(p.x)) \(Int(p.y)) \(Int(s.width)) \(Int(s.height))")
"""


def axwin(tmp, *args):
    exe = os.path.join(tmp, "axwin")
    if not os.path.exists(exe):
        src = os.path.join(tmp, "axwin.swift")
        open(src, "w").write(AXSET_SRC)
        c = subprocess.run(["swiftc", "-O", "-o", exe, src], capture_output=True, text=True)
        if c.returncode != 0:
            raise SystemExit("ax helper build failed: " + c.stderr[-300:])
    r = subprocess.run([exe] + [str(a) for a in args], capture_output=True, text=True)
    return r.stdout.strip()


def front_owner(d):
    """`front` is "<owner> <x> <y> <w> <h>" and the owner may contain spaces."""
    f = (d.get("front") or "").split()
    return " ".join(f[:-4]) if len(f) >= 5 else None


def phase_ontop(rep, tmp):
    """One on-top trial, in the state the feature exists for: a front window flush to x = 0 and at
    least 1200 wide, so the observer publishes `flush` and hides the strip.  The keeper must then
    replay every tile's pose and raise it, so the strip is still drawn above that window.

    The flush window is made with AX on the *front window's own app* (frame 0,0,full) rather than a
    macOS full-screen Space: a full-screen Space moves the app off the stage's Space and most tiles
    are then not composited at all, which measures the Space switch, not on-top."""
    reveal()
    M = C.wmctl()
    tiles = [t["id"] for t in C.rail_tiles() if t["owner"] != "WindowManager"]
    rep["ontop"] = {"tiles": tiles}
    if not tiles:
        rep["ontop"]["skipped"] = "no strip tiles on screen"
        return
    jout(sh(["teach"], 300))                 # on-top replays `rp`; a teach pass refreshes it
    reveal()
    d = doc()
    owner = front_owner(d)
    before = None
    f = (d.get("front") or "").split()
    if len(f) >= 5:
        before = [int(v) for v in f[-4:]]
    rep["ontop"].update({"front_owner": owner, "front_before": before})
    if not owner or not before:
        rep["ontop"]["skipped"] = "no front window in the document"
        return
    try:
        rep["ontop"]["made_flush"] = axwin(tmp, owner, "frame", 0, 0, -1, -1)
        t0 = time.time()
        d = {}
        while time.time() - t0 < 12:
            d = doc()
            if d.get("flush"):
                break
            time.sleep(0.3)
        time.sleep(1.0)
        wins = {w["id"]: w for w in M.probe_wins()}
        rep["ontop"].update({
            "flush": d.get("flush"), "front_x": d.get("front_x"),
            "drawn": [i for i in tiles if wins.get(i) and (wins[i].get("x") or 0) >= 0],
            "layer3": [i for i in tiles if wins.get(i) and wins[i].get("layer") == 3],
            "frames": {str(i): {k: wins[i].get(k) for k in ("x", "y", "w", "h", "layer")}
                       for i in tiles if i in wins},
            "hb": {k: hb().get(k) for k in ("replay", "bases", "rps")},
        })
    finally:
        if before:
            try:
                rep["ontop"]["restore_front"] = axwin(tmp, owner, "frame", *before)
            except Exception:
                pass
        time.sleep(1.5)
        reveal()
        M.force_writes(passes=1)             # let the keeper lower the tiles again
        time.sleep(0.5)
        wins = {w["id"]: w for w in M.probe_wins()}
        rep["ontop"]["lowered"] = [i for i in tiles
                                   if wins.get(i) and wins[i].get("layer") == 3]
        rep["ontop"]["after"] = {k: doc().get(k) for k in ("flush", "front_x", "strip_on")}


def phase_stale(rep, tmp, s=1.5):
    """The stale-base trial (issue #4).

    With the strip drawn, a test window joins the current stage as a tile, so the other tiles are
    laid out narrower.  Teach in that layout (bases recorded against the narrow drawing), then
    close the test tile: the remaining tiles are re-laid out *wider* in place, with no hide.  Every
    new candidate then has a smaller m0 than the stale base, so the largest-m0 rule can never
    accept it -- that is the 1.575 failure.  The rail id-set changed, so the base set must be
    dropped; then `resize 1.5` must scale every remaining tile."""
    title = "round3-tile-%d" % (int(time.time()) % 100000)
    reveal()
    merge_cfg(trace=True)
    before = set(frames())
    before_ids = {int(k) for k in before}
    bases_before = hb().get("bases")
    p, cgid = spawn_tile(title)
    try:
        t0 = time.time()
        a = None
        raised = False
        while time.time() - t0 < 30:
            reveal()
            rows = C.rail_tiles()
            ids = {t["id"] for t in rows}
            if cgid and cgid in ids:
                a = cgid
                break
            if cgid and not raised and time.time() - t0 > 3:
                # The new window opens as the *front* window, which Stage Manager does not draw as
                # a tile.  Raise another window of the same stage so ours becomes a tile.
                owner = next((t["owner"] for t in rows if t.get("owner")), None)
                if owner:
                    subprocess.run(["osascript", "-e",
                                    'tell application "%s" to activate' % owner],
                                   capture_output=True)
                raised = True
            time.sleep(0.4)
        rep["stale"] = {"tiles_before": sorted(before), "trial_cgid": cgid,
                        "trial_tile": a, "bases_before": bases_before}
        if a is None:
            rep["stale"]["skipped"] = "the test tile did not join the current stage"
        after_join = set(frames())
        rep["stale"]["tiles_with_trial_tile"] = sorted(after_join)
        if a is None:
            rep["stale"]["shrank_in_place"] = False
            return
        rep["stale"]["joined_in_place"] = before <= after_join
        teach = jout(sh(["teach"], 300)) or {}
        rep["stale"]["teach_with_trial_tile"] = {
            "ok": teach.get("ok"), "tiles": teach.get("tiles"),
            "no_base": teach.get("no_base"), "wait": teach.get("waits"),
            "secs": teach.get("secs")}
        rep["stale"]["bases_after_teach"] = hb().get("bases")
        rep["stale"]["railchg_after_teach"] = hb().get("railchg")
        rep["stale"]["hb_before_close"] = {k: hb().get(k) for k in
                                           ("bases", "railchg", "unsettled")}
        chg0 = hb().get("railchg") or 0
        kill_tile(p, title)
        t0 = time.time()
        gone = set(frames())
        while time.time() - t0 < 30:
            gone = set(frames())
            if a not in gone:
                break
            time.sleep(0.4)
        rep["stale"]["tiles_after_close"] = sorted(gone)
        # wait for the payload to act on the new id-set: bases drop and railchg advances
        h = wait_hb(lambda h: (h.get("railchg") or 0) > chg0, 25.0)
        rep["stale"]["closed_tile_gone"] = a not in gone
        rep["stale"]["shrank_in_place"] = (a not in gone and (before - {a}) <= gone)
        rep["stale"]["railchg_after_close"] = h.get("railchg")
        rep["stale"]["bases_after_close"] = h.get("bases")
        rep["stale"]["hb_after_shrink"] = {k: h.get(k) for k in
                                           ("bases", "railchg", "unsettled", "px", "py")}
        reveal()
        f0 = frames()
        r15 = resize(s)
        h1 = hb()
        f15 = frames()
        r10 = resize(1.0)
        f10 = frames()
        h2 = hb()
        rep["stale"]["resize_1.5"] = {"ok": r15.get("ok"), "err": r15.get("err"),
                                      "tiles": r15.get("tiles"), "teach": r15.get("teach")}
        rep["stale"]["ratios"] = ratios(r15)
        rep["stale"]["tiles_at_1.5"] = sorted(f15)
        rep["stale"]["hb_after_1.5"] = {k: h1.get(k) for k in
                                        ("bases", "railchg", "unsettled", "px", "py", "psrc",
                                         "pivmiss")}
        rep["stale"]["resize_1.0"] = {"ok": r10.get("ok"), "ratios": ratios(r10),
                                      "xy": r10.get("xy")}
        rep["stale"]["restore"] = {k: {ax: round(f10[k][ax] - f0[k][ax], 1)
                                       for ax in ("x", "y", "w", "h")}
                                   for k in f0 if k in f10}
        rep["stale"]["hb_final"] = {k: h2.get(k) for k in ("bases", "railchg", "unsettled")}
        log = sh(["log"], 120)["out"]
        rep["stale"]["payload_log"] = [l for l in log.splitlines() if "RAIL" in l or
                                       "APPLYCFG" in l][-10:]
        tr = sh(["trace"], 180)["out"].splitlines()
        rep["stale"]["trace_after"] = {"count": len(tr), "last": tr[-6:]}
    finally:
        kill_tile(p, title)
        merge_cfg(trace=False)


def main():
    args = sys.argv[1:]
    out = os.path.join(ROOT, "re", "round3")
    phases = ["pivot", "constant", "trace", "ontop", "stale"]
    stop = True
    tmp = os.path.join("/tmp", "sturgeon-round3")
    while args:
        a = args.pop(0)
        if a == "--out":
            out = args.pop(0)
        elif a == "--phases":
            phases = args.pop(0).split(",")
        elif a == "--no-stop":
            stop = False
        else:
            raise SystemExit("usage: proof-round3.py [--out DIR] [--phases a,b] [--no-stop]")
    if not LOCK:
        raise SystemExit("refusing: set WMTEST_LOCK to the lock directory this session took")
    if not os.path.isdir(LOCK):
        raise SystemExit("refusing: %s is not held by this session" % LOCK)
    if os.geteuid() != 0:
        raise SystemExit("refusing: run as root (the task port needs it), e.g. through the"
                         " NOPASSWD wrapper this machine grants, with cwd %s" % ROOT)
    if armed():
        raise SystemExit("refusing: the machine is already ARMED by someone else")
    os.makedirs(out, exist_ok=True)
    os.makedirs(tmp, exist_ok=True)
    rep = {"when": time.strftime("%Y-%m-%dT%H:%M:%S"), "phases": phases,
           "payload_sha256": None, "armed": None}
    try:
        with open(os.path.join(ROOT, "wmship", "payload.img"), "rb") as f:
            import hashlib
            rep["payload_sha256"] = hashlib.sha256(f.read()).hexdigest()[:16]
    except Exception:
        pass
    st = sh(["start"], 600)
    rep["start"] = {"rc": st["rc"], "tail": st["out"].strip().splitlines()[-6:]}
    if not armed():
        sh(["stop"], 300)
        raise SystemExit("could not arm: %r" % (st,))
    rep["armed"] = True
    try:
        reveal()
        rep["phase_errors"] = {}
        for name, fn in (("pivot", lambda: phase_pivot(rep)),
                         ("constant", lambda: phase_constant(rep)),
                         ("trace", lambda: phase_trace(rep)),
                         ("ontop", lambda: phase_ontop(rep, tmp)),
                         ("stale", lambda: phase_stale(rep, tmp))):
            if name not in phases:
                continue
            try:
                fn()
            except Exception as e:           # one phase failing must not cost the other evidence
                rep["phase_errors"][name] = str(e)
        rep["hb_final"] = {k: hb().get(k) for k in
                           ("bases", "learn", "railchg", "unsettled", "px", "py", "psrc",
                            "replay", "pivmiss")}
        rep["status_armed"] = sh(["status"], 120)["out"].strip().splitlines()[:4]
    finally:
        if stop:
            stp = sh(["stop"], 300)
            rep["stop"] = {"rc": stp["rc"], "tail": stp["out"].strip().splitlines()[-8:]}
            rep["status_after"] = sh(["status"], 120)["out"].strip()
        with open(os.path.join(out, "proof-round3-%s.json"
                               % rep["when"].replace(":", "")), "w") as f:
            json.dump(rep, f, indent=1)
    print(json.dumps(rep, indent=1))


if __name__ == "__main__":
    main()
