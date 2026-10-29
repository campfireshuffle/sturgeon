#!/usr/bin/env python3
"""wmctl.py — the commands behind wmctl.sh.

  stages                      dump the WM registry and map it to the strip's stage titles
  move <stage> [--cgid N]     move a window (default: the frontmost one) to a named stage
  resize <s>                  set the strip's rendered scale (1.0 = natural)
  gesture up|down [n]         drive the scale with Option+scroll (r21gesture must be running)
  key up|down [n]             drive the scale with Ctrl+Option+Up/Down
  warm                        hover the tiles so the WM writes every strip pose (learn bases)
  level <0|3>                 raise/lower the strip windows with the WM's own transaction
  measure                     the strip tiles and the front window, as JSON
  dump [--path P]             write the registry dump through the WM
  status [--json]             supervisor + capability status
"""
import argparse
import json
import os
import subprocess
import sys
import time

# Paths come from wmlayout (this file is always at <root>/wm/wmctl.py): the checkout keeps each
# round's own build directory, the app carries one flat bin/.  Nothing here is a repo constant.
W = os.path.dirname(os.path.realpath(__file__))
_ROOT = os.path.dirname(W)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
import wmlayout as LAYOUT                                  # noqa: E402

D = "/tmp/wm"
CFG = D + "/cfg.json"
REQ = D + "/req.json"
RES = D + "/res.json"
REG = D + "/reg.txt"

AX = LAYOUT.bin_path("r19ax")
R8 = LAYOUT.bin_path("r8state")
PROBE = LAYOUT.bin_path("r21probe")
MOVE = LAYOUT.bin_path("r21move")
CLICK = LAYOUT.bin_path("r20click")
SCROLL = LAYOUT.bin_path("r21scroll")
KEY = LAYOUT.bin_path("wmkey")
GESTURE = LAYOUT.bin_path("r21gesture")
GESTLOG = D + "/gesture.log"
GESTOUT = D + "/gesture.json"
PIVOT = (16.0, 490.0)
GUTTER = 286.92


def sh(c, t=40):
    try:
        return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=t).stdout
    except Exception:
        return ""


def jload(p, dflt=None):
    try:
        return json.load(open(p))
    except Exception:
        return dflt


def r8state():
    return jload_str(sh(R8 + " '*' --json", 20)) or {"wins": [], "piles": []}


def jload_str(s):
    try:
        return json.loads(s)
    except Exception:
        return None


def probe_wins():
    return jload_str(sh(PROBE, 20)) or []


def live_ids(st=None):
    st = st or r8state()
    # layer 3 counts: a strip window raised by the on-top feature is still a live window.
    out = sorted(w["wid"] for w in st.get("wins", [])
                 if w.get("on") and w.get("layer") in (0, 3)
                 and w["w"] >= 300 and w["h"] >= 250)
    if not out:                      # the WM was busy; fall back to the on-screen list
        out = sorted(w["id"] for w in probe_wins()
                     if w.get("layer") in (0, 3) and w["w"] >= 300 and w["h"] >= 250)
    return out


def piles(st=None):
    st = st or r8state()
    return {p["title"]: sorted(p["ids"]) for p in st.get("piles", [])}


# ---------------------------------------------------------------- registry
def parse_dump(path=REG):
    sets, cur = [], None
    try:
        lines = open(path, errors="replace").read().split("\n")
    except Exception:
        return sets
    for line in lines:
        if line.startswith("REG "):
            continue
        if line.startswith("SET"):
            head = line.split(" w=")[0]
            try:
                words = [int(x, 16) for x in line.split("w=")[1].split()[0].split("/")]
            except Exception:
                continue
            cur = {"id": head.split("id=")[1].strip().strip("'"),
                   "w": words, "members": []}
            sets.append(cur)
        elif line.startswith("   ") and cur is not None:
            f = line.split()
            cg = [x for x in f if x.startswith("cgid=")]
            cur["members"].append({"addr": f[0],
                                   "ser": int(f[1].split("=")[1]),
                                   "cgid": int(cg[0].split("=")[1]) if cg else 0,
                                   "desc": " ".join(f[4:])})
    return sets


def stage_map(path=REG):
    st = r8state()
    pl = st.get("piles", [])
    wins = {w["wid"]: w for w in st.get("wins", [])}
    sets = parse_dump(path)
    cur_ids = {w["wid"] for w in st.get("wins", []) if w.get("on")}
    out = []
    for s in sets:
        mem = {m["cgid"] for m in s["members"] if m["cgid"]}
        best, bestn = None, 0
        for p in pl:
            n = len(mem & set(p["ids"]))
            if n > bestn:
                best, bestn = p["title"], n
        if not best:
            for p in pl:
                if set(p["ids"]) and set(p["ids"]) <= mem:
                    best, bestn = p["title"], len(set(p["ids"]))
                    break
        kind = "pile" if best else ("current" if (mem & cur_ids) else "?")
        out.append({"id": s["id"], "w": s["w"], "title": best, "kind": kind,
                    "n": len(s["members"]), "cgids": sorted(mem),
                    "members": s["members"]})
    return out


def resolve_stage(title, path=REG):
    if title in (None, "", "current"):
        for m in stage_map(path):
            if m["kind"] == "current":
                return (0, 0), m, "native"
        return None, None, None
    mp = stage_map(path)
    for m in mp:
        if (m["title"] or "").lower() == title.lower():
            return tuple(m["w"]), m, "tag1"
    return None, None, None


# ---------------------------------------------------------------- stage switch (click)
def tiles_ax():
    """The strip's stage tiles as AX reports them (title + AX frame; the frame is the hidden
    pose whenever the strip is retracted)."""
    out = sh("%s tiles" % AX)
    res = []
    for line in out.split("\n"):
        if not line.startswith("TILE "):
            continue
        try:
            ids = [int(x) for x in line.split("ids=[")[1].split("]")[0].replace(" ", "").split(",") if x]
            rest = line.split(" f=")[1].split()
            x, y = [int(v) for v in rest[0].split(",")]
            w, h = [int(v) for v in rest[1].split("x")]
            title = line.split("title=")[1].split(" actions=")[0]
        except Exception:
            continue
        res.append({"ids": ids, "x": x, "y": y, "w": w, "h": h, "title": title})
    return res


def drawn_tile(ids):
    """Where a stage tile is actually *drawn* (CGWindowList geometry, not the AX frame).
    Returns the biggest drawn window among `ids` that sits inside the strip's gutter."""
    want = set(int(i) for i in ids)
    best = None
    for w in probe_wins():
        if w["id"] not in want:
            continue
        if not (0 <= w["x"] < 320 and 8 <= w["w"] <= 330 and 8 <= w["h"] <= 560):
            continue
        if best is None or w["w"] * w["h"] > best["w"] * best["h"]:
            best = w
    return best


def switch_to(ids, tries=6):
    """Click the stage tile that owns `ids`; verify those windows became live."""
    want = set(int(i) for i in ids)
    for _ in range(tries):
        if want & set(live_ids()):
            return True, {"already_live": sorted(want & set(live_ids()))}
        w = drawn_tile(want)
        if w is None:
            ax = [t for t in tiles_ax() if set(t["ids"]) & want]
            w = max(ax, key=lambda t: t["w"] * t["h"]) if ax else None
        if w is None:
            time.sleep(0.6)
            continue
        sh("%s %d %d" % (CLICK, int(w["x"] + w["w"] / 2), int(w["y"] + w["h"] / 2)))
        time.sleep(1.9)
        if want & set(live_ids()):
            return True, {k: w[k] for k in ("id", "x", "y", "w", "h")}
    return False, None


# ---------------------------------------------------------------- WM requests
def post(req, trigger=399, wait=14.0):
    for f in (REQ, RES):
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
    tmp = REQ + ".tmp"
    json.dump(req, open(tmp, "w"))
    os.replace(tmp, REQ)
    t0 = time.time()
    last = 0.0
    while time.time() - t0 < wait:
        r = jload(RES)
        if r:
            return r
        if time.time() - last > 0.8:
            sh("%s nudge %d 1 0" % (AX, trigger))
            last = time.time()
        time.sleep(0.12)
    return {"ok": False, "error": "timeout waiting for the WM"}


def cmd_dump(args):
    r = post({"op": "dump", "state": "new", "path": args.path}, trigger=args.trigger)
    if not r.get("ok"):
        print("dump failed: %s" % r, file=sys.stderr)
        return 1
    print(open(r["path"]).read())
    return 0


def cmd_switch(args):
    ids = args.ids if isinstance(args.ids, list) else [int(x) for x in str(args.ids).split(",") if x]
    ok, tile = switch_to(ids)
    print(json.dumps({"ok": ok, "tile": tile, "live": live_ids()}, indent=1))
    return 0 if ok else 1


def cmd_stages(args):
    r = post({"op": "dump", "state": "new", "path": REG}, trigger=args.trigger)
    if not r.get("ok"):
        print("registry dump failed: %s" % r, file=sys.stderr)
        return 1
    mp = stage_map()
    pl = piles()
    print("strip piles: " + ", ".join("%s%s" % (t, i) for t, i in pl.items()))
    for m in mp:
        print("SET kind=%-8s title=%-12s n=%d id=%r w=%016x/%016x cgids=%s" % (
            m["kind"], m["title"] or "-", m["n"], m["id"], m["w"][0], m["w"][1],
            m["cgids"]))
    return 0


def frontmost_cgid():
    out = sh("%s front" % AX).strip()
    try:
        return int(out.split("cgid=")[1].split()[0])
    except Exception:
        return 0


def move_window(cgid, stage, wait=14.0, return_home=True):
    """Move `cgid` to `stage` (a strip title, or "current"); returns the result dict."""
    words, meta, mode = resolve_stage(stage)
    if mode is None:
        return {"ok": False, "error": "no such target stage: %r" % stage,
                "stages": [m["title"] or m["kind"] for m in stage_map()]}
    before = next((w for w in r8state().get("wins", []) if w["wid"] == cgid), None)
    user = live_ids()
    req = {"op": "move", "state": "new", "cgid": cgid, "mode": mode,
           "w0": "%016x" % words[0], "w1": "%016x" % words[1],
           "stage": stage, "any_entry": False}
    t0 = time.time()
    r = post(req, trigger=cgid, wait=wait)
    if not r.get("ok"):
        return {"ok": False, "error": r.get("error"), "raw": r}
    switched = None
    if mode == "tag1" and return_home:
        time.sleep(1.4)
        presented = live_ids()
        if user and set(user) - set(presented):
            ok, tile = switch_to(user)
            switched = {"ok": ok, "tile": tile, "presented": presented}
    return {"ok": True, "cgid": cgid, "target": stage, "mode": mode,
            "target_id": meta["id"] if meta else None,
            "dur": round(time.time() - t0, 2), "before": before,
            "ops": r.get("ops"), "switch_back": switched}


def cmd_move(args):
    cgid = args.cgid or frontmost_cgid()
    if not cgid:
        print("no frontmost window (use --cgid)", file=sys.stderr)
        return 2
    out = move_window(cgid, args.stage, args.wait, args.return_home)
    if not out.get("ok"):
        print("move failed: %s" % out, file=sys.stderr)
        return 1
    win = next((w for w in r8state().get("wins", []) if w["wid"] == cgid), None)
    out["after"] = win
    out["live_after"] = live_ids()
    out["in_sets"] = [m["title"] or m["kind"] for m in stage_map() if cgid in m["cgids"]]
    print(json.dumps(out, indent=1))
    return 0


# ---------------------------------------------------------------- strip
def read_cfg():
    c = jload(CFG, {}) or {}
    base = {"births": True, "replay": True, "dilate": True, "levels": True,
            "level_manual": 0, "s": 1.0, "qx": PIVOT[0], "qy": PIVOT[1], "gen": 0}
    base.update(c)
    return base


def write_cfg(c):
    tmp = CFG + ".tmp"
    json.dump(c, open(tmp, "w"))
    os.replace(tmp, CFG)


def wait_gen(gen, t=4.0):
    t0 = time.time()
    while time.time() - t0 < t:
        hb = jload(D + "/hb.json", {}) or {}
        if (hb.get("strip") or {}).get("gen_applied") == gen:
            return True
        time.sleep(0.05)
    return False


def force_writes(passes=2):
    """Hover every stage tile so the WM re-emits its per-tile 4x4.  The keeper composes the
    current cfg (scale, replay pose, level) onto that very write, so no debugger interrupt is
    needed - which is what used to be able to wedge lldb.

    `passes=2` is the teaching sweep: a base is the pose an animation *settles* on, so the tile has
    to be visited, left and given time to come back.  A measurement sweep only needs every tile to
    be written once (`passes=1`); `ctl.py resize` uses that and re-sweeps if a tile did not take."""
    skip = ("WindowManager", "Window Server", "Dock", "Notification Center",
            "CursorUIViewService")
    n = 0
    for _pass in range(max(1, int(passes))):
        apps = [w for w in probe_wins() if w.get("owner") not in skip
                and 0 <= w["x"] < 320 and 8 <= w["w"] <= 330 and 8 <= w["h"] <= 560]
        for a in apps:
            # enter at the tile's exposed left edge: the current stage's window covers most of
            # the rail and only the first ~30 px of the gutter receive the pointer.  The start
            # point is inside the gutter, not in the middle of the screen (it used to be 700,500):
            # every event stream begins by teleporting to (x1,y1), so starting mid-screen made the
            # strip retract and re-reveal between tiles, which sets a 0.30 s teach hold on every
            # visit and turns "did this tile settle" into a timing race (round 3, issue #4).
            sh("%s 3 500 %d %d 24" % (MOVE, int(a["x"] + 6), int(a["y"] + a["h"] / 2)))
            time.sleep(0.3)
            n += 1
        # Park the pointer in the gutter margin, not in the middle of the screen: the strip
        # retracts within ~0.4 s of the pointer leaving the left edge, and every caller measures
        # right after a sweep (0.35 s).  x = 3 is left of the first tile, so it keeps the strip
        # drawn without hovering any tile.
        #
        # The stream must *start* in the gutter too (it begins by teleporting to (x1,y1)).  It
        # used to start at (30,400), which is inside a tile whenever one is drawn across y=400:
        # that re-hovered that tile after every real tile had been visited, so its unhover burst
        # was the newest candidate in the keeper and the last pose activity of the sweep -- and a
        # candidate needs a *later* keeper call to be promoted (regression: Orca, tile 9547, on
        # the owner's strip, where (30,400) sits inside it).  Parking from the gutter leaves the
        # sweep's last real visit as its final burst, and `ctl.wait_bases` supplies the call.
        sh("%s 3 500 3 500 2" % MOVE)
        time.sleep(0.4)
    return n


NATURAL = D + "/natural.json"


def set_cfg(kv):
    c = read_cfg()
    for k, v in kv.items():
        c[k] = v
    c["gen"] = int(c.get("gen") or 0) + 1
    write_cfg(c)
    return c


def cmd_set(args):
    kv = {}
    for a in args.pairs:
        k, _, v = a.partition("=")
        if v.lower() in ("true", "false"):
            kv[k] = v.lower() == "true"
        else:
            try:
                kv[k] = float(v) if "." in v else int(v)
            except ValueError:
                kv[k] = v
    c = set_cfg(kv)
    print(json.dumps({"set": kv, "cfg": c}, indent=1))
    return 0


def rail_tiles():
    return [t for t in measure()["tiles"] if t["owner"] != "WindowManager"]


def natural():
    return jload(NATURAL, {}) or {}


def apply_scale(s, tries=4):
    """Set the strip's scale and verify it per tile, sweeping again until every tile that has a
    natural width has reached s x natural.  The keeper applies the scale on each WM pose write,
    so a window the WM has not re-emitted yet is caught by the next sweep."""
    s = round(float(s), 3)
    nat = natural()
    if abs(s - 1.0) > 1e-9 and not nat:
        c = read_cfg()
        c.update({"s": 1.0, "dilate": False, "gen": int(c.get("gen") or 0) + 1})
        write_cfg(c)
        force_writes()
        time.sleep(0.4)
        nat = {str(t["id"]): t["w"] for t in rail_tiles()}
        json.dump(nat, open(NATURAL, "w"))
    c = read_cfg()
    c.update({"s": s, "dilate": abs(s - 1.0) > 1e-9, "gen": int(c.get("gen") or 0) + 1})
    write_cfg(c)
    if abs(s - 1.0) < 1e-9 and not nat:
        nat = {str(t["id"]): t["w"] for t in rail_tiles()}
        json.dump(nat, open(NATURAL, "w"))
    rep = {"s": s, "tries": 0, "tiles": [], "ok": False}
    for i in range(tries):
        force_writes()
        time.sleep(0.35)
        rep["tries"] = i + 1
        rep["tiles"] = [{"id": t["id"], "owner": t["owner"], "w": t["w"],
                         "natural": nat.get(str(t["id"])),
                         "ratio": round(t["w"] / nat[str(t["id"])], 3)
                         if str(t["id"]) in nat else None}
                        for t in rail_tiles()]
        got = [t for t in rep["tiles"] if t["ratio"] is not None]
        rep["ok"] = bool(got) and all(abs(t["ratio"] - s) <= 0.06 for t in got)
        if rep["ok"]:
            break
    json.dump(rep, open(D + "/last_resize.json", "w"))
    return rep


def cmd_resize(args):
    s = max(0.4, min(1.5, float(args.scale)))
    rep = apply_scale(s)
    print(json.dumps(rep, indent=1))
    return 0 if rep["ok"] else 1


def cmd_pulse(args):
    n = force_writes()
    print(json.dumps({"sweeps": n}))
    return 0


def cmd_gesture(args):
    n = args.n
    cap = args.max
    dy = -25 if args.direction == "up" else 34
    sh("pkill -x r21gesture")
    time.sleep(0.3)
    sh("(cd %s && nohup ./r21gesture --out %s >%s 2>&1 &)" % (
        os.path.dirname(GESTURE), GESTOUT, GESTLOG))
    time.sleep(0.8)
    for _ in range(n):
        sh("%s 700 500 %d 1 opt" % (SCROLL, dy))
        time.sleep(0.07)
    time.sleep(0.5)
    g = jload(GESTOUT, {}) or {}
    s = float(g.get("s", 1.0))
    if cap is not None and s > cap:
        s = cap
    rep = apply_scale(s)
    rep["gesture_s"] = s
    print(json.dumps(rep, indent=1))
    return 0 if rep["ok"] else 1


def cmd_key(args):
    n = args.n
    kc = 126 if args.direction == "up" else 125
    sh("pkill -x r21gesture")
    time.sleep(0.3)
    sh("(cd %s && nohup ./r21gesture --out %s >%s 2>&1 &)" % (
        os.path.dirname(GESTURE), GESTOUT, GESTLOG))
    time.sleep(0.8)
    for _ in range(n):
        sh("%s %d ctrl-opt" % (KEY, kc))
        time.sleep(0.12)
    time.sleep(0.5)
    g = jload(GESTOUT, {}) or {}
    s = float(g.get("s", 1.0))
    rep = apply_scale(s)
    rep["key_s"] = s
    print(json.dumps(rep, indent=1))
    return 0 if rep["ok"] else 1


def cmd_warm(args):
    n = force_writes()
    time.sleep(0.4)
    hb = jload(D + "/hb.json", {}) or {}
    print(json.dumps({"warmed": n, "base": (hb.get("strip") or {}).get("base")}))
    return 0


def measure():
    ws = probe_wins()
    skip = {"Window Server", "Dock", "Notification Center", "CursorUIViewService"}
    rail, front = [], None
    for w in ws:
        if w.get("layer") not in (0, 3):
            continue
        if front is None and w.get("layer") in (0, 3) and w["owner"] not in skip \
                and w["w"] >= 600 and w["h"] >= 300:
            front = w
        if 0 <= w["x"] < 320 and 8 <= w["w"] <= 330 and 8 <= w["h"] <= 560 \
                and w["owner"] not in skip:
            rail.append(w)
    return {"tiles": [{"id": t["id"], "owner": t["owner"], "x": t["x"], "y": t["y"],
                       "w": t["w"], "h": t["h"], "layer": t["layer"], "i": t["i"]}
                      for t in rail],
            "front": front}


def cmd_measure(args):
    print(json.dumps(measure(), indent=1))
    return 0


def cmd_cache(args):
    if sh("pgrep -x lldb").strip():
        open(D + "/cmd", "w").write("script print(wm.cache())\n")
        time.sleep(0.8)
    print(sh("grep WM_CACHE %s/lldb.log | tail -1" % D))
    return 0


def set_level_manual(n):
    c = read_cfg()
    gen = int(c.get("gen") or 0) + 1
    c.update({"level_manual": int(n), "gen": gen})
    write_cfg(c)
    force_writes()          # any write makes the keeper push the level for every rail window
    time.sleep(0.4)
    force_writes()
    return gen


def cmd_unlevel(args):
    """Drop every strip window - and any window the raise left at layer 3 - back to layer 0."""
    three = sorted({w["id"] for w in probe_wins() if w.get("layer") == 3})
    c = read_cfg()
    c.update({"level_manual": 0, "level_zero": three,
              "gen": int(c.get("gen") or 0) + 1})
    write_cfg(c)
    force_writes()
    time.sleep(0.5)
    force_writes()
    c = read_cfg()
    c["level_zero"] = []
    write_cfg(c)
    left = sorted({w["id"] for w in probe_wins() if w.get("layer") == 3})
    print(json.dumps({"lowered": three, "still_layer3": left}))
    return 0


def cmd_level(args):
    set_level_manual(args.level)
    time.sleep(0.7)
    tiles = [t for t in measure()["tiles"] if t["owner"] != "WindowManager"]
    print(json.dumps({"level_manual": args.level,
                      "layers": sorted({t["layer"] for t in tiles}), "tiles": len(tiles)}))
    return 0


def cmd_status(args):
    # ask the in-WM module for fresh counters (it only writes hb.json from memory)
    if sh("pgrep -x lldb").strip():
        try:
            m0 = os.path.getmtime(D + "/hb.json")
        except OSError:
            m0 = 0
        open(D + "/cmd", "w").write("script print(wm.status())\n")
        t0 = time.time()
        while time.time() - t0 < 1.5:
            try:
                if os.path.getmtime(D + "/hb.json") > m0:
                    break
            except OSError:
                pass
            time.sleep(0.05)
    sup = jload(D + "/status.json", {}) or {}
    hb = jload(D + "/hb.json", {}) or {}
    arm = jload(D + "/arm.json", {}) or {}
    cfg = read_cfg()
    st = jload(D + "/state.json", {}) or {}
    obs = {"pending": os.path.exists(D + "/pending.txt"),
           "pending_age": round(time.time() - os.path.getmtime(D + "/pending.txt"), 2)
           if os.path.exists(D + "/pending.txt") else None,
           "state_age": round(time.time() - os.path.getmtime(D + "/state.json"), 2)
           if os.path.exists(D + "/state.json") else None,
           "gesture": bool(sh("pgrep -x r21gesture").strip())}
    lldb = sh("pgrep -x lldb").split()
    out = {"supervisor": sup, "wm_pid": sh("pgrep -x WindowManager").strip(),
           "lldb": lldb, "debugserver": sh("pgrep -f Resources/debugserver").split(),
           "arm": arm, "cfg": cfg, "hb": hb, "observers": obs,
           "strip": {"front_x": st.get("front_x"), "flush": st.get("flush"),
                     "strip_on": st.get("strip_on"),
                     "rail_now": st.get("rail_now")}}
    armed = sup.get("state") == "attached" and bool(lldb)
    bps = set(arm.get("bps") or [])
    out["capabilities"] = {
        "births": {"armed": armed and "DRV" in bps and "COMPUTE" in bps
                   and "APPLY" in bps and cfg.get("births", True)
                   and obs["pending"] and (obs["pending_age"] if obs["pending_age"] is not None else 99) < 2.0,
                   "injected": (hb.get("births") or {}).get("injected")},
        "move": {"armed": armed and "DRV" in bps and "COMPUTE" in bps
                 and "APPLY" in bps and (obs["state_age"] if obs["state_age"] is not None else 99) < 2.0,
                 "moves": (hb.get("move") or {}).get("moves")},
        "on_top": {"armed": armed and "SLSTransactionSetWindowTransform3D" in bps
                   and cfg.get("replay", True) and (obs["state_age"] if obs["state_age"] is not None else 99) < 2.0,
                   "taught": (hb.get("strip") or {}).get("taught"),
                   "replayed": (hb.get("strip") or {}).get("replayed")},
        "resize": {"armed": armed and "SLSTransactionSetWindowTransform3D" in bps
                   and cfg.get("dilate") is not None
                   and (obs["state_age"] if obs["state_age"] is not None else 99) < 2.0,
                   "bases": (hb.get("strip") or {}).get("base"),
                   "s": cfg.get("s"), "scaled": (hb.get("strip") or {}).get("scaled")},
    }
    out["all_armed"] = all(v["armed"] for v in out["capabilities"].values())
    # patch mode (round 24): the same capabilities as in-memory code, no debugger at all
    pat = None
    try:
        ps = jload(D + "/p24state.json", {})
        if ps:
            ph = jload(D + "/p24hb.json", {}) or {}
            same = str(ps.get("pid")) == str(out["wm_pid"])
            pat = {"mode": "patch", "installed_pid": ps.get("pid"),
                   "payload": hex(ps.get("addr") or 0), "sites": ps.get("patched") or [],
                   "same_process": same,
                   "armed": bool(same and len(ps.get("patched") or []) == 4),
                   "hb": ph}
            out["all_armed"] = pat["armed"]
    except Exception:
        pat = None
    out["patch"] = pat
    if args.json:
        print(json.dumps(out, indent=1))
    else:
        print("WindowManager %s   lldb %s   state=%s  restarts=%s" % (
            out["wm_pid"] or "-", " ".join(lldb) or "-", sup.get("state"),
            sup.get("restarts")))
        if pat:
            h = pat["hb"] or {}
            print("mode: PATCH  payload=%s pid=%s  sites=%s  armed=%s  counters: inject=%s "
                  "keep=%s learn=%s dil=%s replay=%s level=%s apply=%s" % (
                      pat["payload"], pat["installed_pid"], ",".join(pat["sites"]),
                      pat["armed"], h.get("inject"), h.get("keep"), h.get("learn"),
                      h.get("dil"), h.get("replay"), h.get("level"), h.get("apply")))
        print("observers: births=%s (%ss) strip=%s (%ss) gesture=%s" % (
            obs["pending"], obs["pending_age"], obs["state_age"] is not None,
            obs["state_age"], obs["gesture"]))
        print("breakpoints: %d  slide=%s  self=%s" % (
            len(bps), arm.get("slide"), hex(hb.get("self") or 0)))
        if pat and pat["armed"]:
            print("  births/move/on_top/resize: ON (in-memory patch; the OFF lines below are the "
                  "lldb-mode breakpoint set)")
        for k, v in out["capabilities"].items():
            print("  %-8s %s  %s" % (k, "ARMED " if v["armed"] else "OFF   ",
                                     " ".join("%s=%s" % (a, b) for a, b in v.items()
                                              if a != "armed")))
        print("strip: s=%s  front_x=%s flush=%s strip_on=%s" % (
            cfg.get("s"), out["strip"]["front_x"], out["strip"]["flush"],
            out["strip"]["strip_on"]))
        print("all armed: %s" % out["all_armed"])
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("dump")
    d.add_argument("--path", default=REG)
    d.add_argument("--trigger", type=int, default=399)
    d.set_defaults(fn=cmd_dump)
    s = sub.add_parser("stages")
    s.add_argument("--trigger", type=int, default=399)
    s.set_defaults(fn=cmd_stages)
    m = sub.add_parser("move")
    m.add_argument("stage")
    m.add_argument("--cgid", type=int, default=0)
    m.add_argument("--wait", type=float, default=14.0)
    m.add_argument("--return", dest="return_home", action="store_true", default=True)
    m.add_argument("--no-return", dest="return_home", action="store_false")
    m.set_defaults(fn=cmd_move)
    se = sub.add_parser("set")
    se.add_argument("pairs", nargs="+")
    se.set_defaults(fn=cmd_set)
    r = sub.add_parser("resize")
    r.add_argument("scale", type=float)
    r.set_defaults(fn=cmd_resize)
    g = sub.add_parser("gesture")
    g.add_argument("direction", choices=["up", "down"])
    g.add_argument("n", type=int, nargs="?", default=10)
    g.add_argument("--max", type=float, default=None)
    g.set_defaults(fn=cmd_gesture)
    k = sub.add_parser("key")
    k.add_argument("direction", choices=["up", "down"])
    k.add_argument("n", type=int, nargs="?", default=3)
    k.set_defaults(fn=cmd_key)
    w = sub.add_parser("warm")
    w.set_defaults(fn=cmd_warm)
    ca = sub.add_parser("cache")
    ca.set_defaults(fn=cmd_cache)
    ul = sub.add_parser("unlevel")
    ul.set_defaults(fn=cmd_unlevel)
    lv = sub.add_parser("level")
    lv.add_argument("level", type=int)
    lv.set_defaults(fn=cmd_level)
    me = sub.add_parser("measure")
    me.set_defaults(fn=cmd_measure)
    sw = sub.add_parser("switch")
    sw.add_argument("ids")
    sw.set_defaults(fn=cmd_switch)
    st = sub.add_parser("status")
    st.add_argument("--json", action="store_true")
    st.set_defaults(fn=cmd_status)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
