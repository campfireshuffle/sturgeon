#!/usr/bin/python3
"""ctl.py — the capability side of `work/wmship.sh`: move / resize / level / measure.

Everything here goes through the *payload's own page* (via install.py) or through user-side
observers that only read CGWindowList / AX.  No debugger, no task port for the read side.

  ctl.py move <stage|current|#cgid> [--cgid N]   switch to the stage, then move a window into it
  ctl.py resize <scale>                          strip rendered scale 0.4 .. 1.5 (1.0 = natural)
  ctl.py level <0|3>                             raise/lower the strip windows via the keeper
  ctl.py measure                                 tiles + live windows as JSON
  ctl.py state                                   the state document the payload received
  ctl.py warm                                    hover the tiles so the WM re-emits every pose
  ctl.py cfg                                     print the payload's configuration
"""
import json
import os
import sys
import time

# every path comes from wmlayout (this file is always at <root>/wmship/ctl.py); nothing is
# derived from the cwd, so the same code runs from the checkout and from Sturgeon.app
_HERE = os.path.dirname(os.path.realpath(__file__))
_ROOT = os.path.dirname(_HERE)
for _p in (_ROOT, _HERE, os.path.join(_ROOT, "wm")):
    if _p not in sys.path:
        sys.path.insert(0, _p)
import install as I                                        # noqa: E402

D = I.D
NATURAL = D + "/natural.json"
LAST_RESIZE = D + "/last_resize.json"


def wmctl():
    import wmctl as M
    return M


# ---------------------------------------------------------------- payload cfg
def cfg_get():
    raw = I.rd_sym("_io_cfg", 1536).split(b"\0")[0].decode(errors="replace")
    try:
        return json.loads(raw)
    except Exception:
        return dict(I.CFG_DEFAULT)


def cfg_set(**kw):
    c = cfg_get()
    c.update(kw)
    c["gen"] = int(time.time() * 1000) & 0x7FFFFFFF
    I.write_cfg(json.dumps(c))
    time.sleep(0.30)
    return c


def hb():
    """The payload's heartbeat, sliced by its own length field.  The page is not zero-filled
    behind the text, so splitting on NUL used to append whatever the previous, longer write left
    there and the JSON parse failed silently (round 33)."""
    try:
        n = int.from_bytes(I.rd_sym("_io_hb_len", 4), "little")
        n = max(0, min(n, 1024))
        return json.loads(I.rd_sym("_io_hb", max(1, n))[:n].decode(errors="replace"))
    except Exception:
        return {}


def poses():
    """Per-pose state of the keeper: <wid> <has a taught base> <has our own last write> <level 3?>.
    A tile with no base cannot be replayed, which is exactly the kind of thing that used to be
    inferred from aggregate counters."""
    n = int.from_bytes(I.rd_sym("_io_poses_len", 4), "little")
    n = max(0, min(n, 2048))
    rows = []
    for line in I.rd_sym("_io_poses", max(1, n))[:n].decode(errors="replace").split("\n"):
        f = line.split()
        if len(f) == 4:
            rows.append({"wid": int(f[0]), "base": int(f[1]), "mine": int(f[2]),
                         "lvl": None if f[3] == "9" else int(f[3])})
    return rows


def state_doc():
    """The document the payload itself received, read back out of its page (round 33: D1 proof).

    Returns the byte length the helper published, the seqlock generation, whether the text is a
    complete JSON object, and the two values the keeper gates on -- so "both present and fresh"
    is an observable, not an assumption.  The read is retried while the seqlock moves, because this
    reader is outside the payload and would otherwise see a document mid-write."""
    for _ in range(6):
        g0 = int.from_bytes(I.rd_sym("_io_st_gen", 4), "little")
        n = int.from_bytes(I.rd_sym("_io_st_len", 4), "little")
        n = max(0, min(n, 16384))
        txt = I.rd_sym("_io_st", max(1, n))[:n].decode(errors="replace")
        g1 = int.from_bytes(I.rd_sym("_io_st_gen", 4), "little")
        if g0 == g1 and not (g0 & 1):
            break
        time.sleep(0.02)
    d = None
    try:
        d = json.loads(txt)
    except Exception:
        d = None
    return {"len": n, "gen": g1, "complete": txt.rstrip().endswith("}"),
            "parsed": d is not None,
            "flush": (d or {}).get("flush"), "has_flush": "flush" in (d or {}),
            "rail_now": (d or {}).get("rail_now"), "has_rail_now": "rail_now" in (d or {}),
            "strip_on": (d or {}).get("strip_on"), "has_strip_on": "strip_on" in (d or {}),
            "front_x": (d or {}).get("front_x"),
            "rail_x": next((r.get("x") for r in (d or {}).get("rail", [])
                            if r.get("id") in ((d or {}).get("rail_now") or [])), None)}


def wait_gen(gen, t=6.0):
    t0 = time.time()
    while time.time() - t0 < t:
        h = hb()
        if (h.get("strip") or {}).get("gen_applied") == gen:
            return True
        time.sleep(0.05)
    return False


# ---------------------------------------------------------------- measure
def rail_tiles():
    M = wmctl()
    return [t for t in M.measure()["tiles"] if t["owner"] != "WindowManager"]


def natural():
    try:
        return json.load(open(NATURAL))
    except Exception:
        return {}


# ---------------------------------------------------------------- resize
def apply_scale(s, tries=4):
    """Scale the strip and verify it per tile against each tile's natural width.  The keeper
    applies the scale on every WM pose write, so a tile the WM has not re-emitted yet is caught
    by the next sweep (each sweep is a hover over every tile: user-side mouse moves only).

    The natural-width record is keyed by window id, so a change in the stage set (a stage switch,
    a window closing) used to leave stale entries behind and report `ok: false` while the
    geometry was right (round 32, reporting defect).  It is now refreshed whenever the set of
    tiles differs from the record."""
    M = wmctl()
    s = round(float(s), 3)
    nat = natural()
    live = {str(t["id"]): t["w"] for t in rail_tiles()}
    if not live:
        return {"s": s, "ok": False, "err": "no strip tiles on screen (reveal the strip first)",
                "tiles": []}
    if set(live) != set(nat):
        cfg_set(s=1.0, dilate=False, teach=False)
        M.force_writes()
        time.sleep(0.45)
        nat = {str(t["id"]): t["w"] for t in rail_tiles()}
        json.dump(nat, open(NATURAL, "w"), indent=1)
    # Teaching is off while this command sweeps (round 34): a hover *lift* is a transient pose the
    # WM restores from its own copy without going through the keeper hook, so a base learned from a
    # lift renders `1.5 x lift` (measured 1.505-1.746).  The base is taught by the strip's own
    # reveal/layout writes, before any pointer input.
    c = cfg_set(s=s, dilate=abs(s - 1.0) > 1e-9, qx=16.0, qy=490.0, teach=False)
    rep = {"s": s, "gen": c["gen"], "tries": 0, "tiles": [], "ok": False}
    for i in range(tries):
        M.force_writes()
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
    cfg_set(teach=True)          # the next layout write may teach the resting pose again
    rep["hb"] = {k: hb().get(k) for k in ("strip", "apply", "dil")}
    json.dump(rep, open(LAST_RESIZE, "w"), indent=1)
    return rep


# ---------------------------------------------------------------- move
def wait_res(want, t=20.0):
    """The payload publishes its last result in the page; wait for the request to be serviced."""
    t0 = time.time()
    while time.time() - t0 < t:
        try:
            ss = I.rd_sym("_io_ss", 64).split(b"\0")[0].decode(errors="replace")
            n = int.from_bytes(I.rd_sym("_io_res_len", 4), "little")
            res = I.rd_sym("_io_res", max(1, min(n, 256)))[:min(n, 256)].decode(errors="replace")
        except Exception:
            ss, res = "", ""
        if ss.startswith("done") and res:
            try:
                return json.loads(res)
            except Exception:
                return {"ok": False, "raw": res}
        time.sleep(0.15)
    return {"ok": False, "err": "timeout"}


def move(stage, cgid=0):
    M = wmctl()
    st = M.r8state()
    piles = {p["title"]: sorted(p["ids"]) for p in st.get("piles", [])}
    title = (stage or "current")
    if title not in ("current", "") and title not in piles:
        return {"ok": False, "err": "no such stage", "stages": list(piles)}
    switched = None
    if title not in ("current", ""):
        # Switch by activating an app that lives in that stage: the strip does not have to be
        # visible, so this works when it is retracted (a coordinate click cannot).
        owners = [w["owner"] for w in st.get("wins", []) if w["wid"] in piles[title]]
        switched = {"owners": owners, "mode": "activate"}
        for o in owners:
            M.sh('osascript -e \'tell application "%s" to activate\'' % o, 15)
            time.sleep(1.4)
            if set(piles[title]) & set(M.live_ids()):
                switched["ok"] = True
                break
        if not switched.get("ok"):
            ok, tile = M.switch_to(piles[title])
            switched = {"ok": ok, "tile": tile, "mode": "click"}
        if not switched.get("ok"):
            return {"ok": False, "err": "could not make %r current" % title, "switch": switched}
        time.sleep(0.6)
    if not cgid:
        cgid = M.frontmost_cgid()
    if not cgid:
        return {"ok": False, "err": "no source window (use --cgid)"}
    before = next((w for w in M.r8state().get("wins", []) if w["wid"] == cgid), None)
    I.write_req({"op": "move", "cgid": cgid})
    res = {"ok": False, "err": "not serviced"}
    t0 = time.time()
    nudge = 0
    while time.time() - t0 < 22:
        h = hb()
        if h.get("move") or h.get("msubj"):
            res = wait_res(None, 4.0)
            if res.get("ok"):
                break
        nudge += 1
        M.sh("%s nudge %d 1 0" % (M.AX, cgid))
        time.sleep(0.5)
        res = wait_res(None, 0.4)
        if res.get("ok") or res.get("err"):
            if res.get("ok"):
                break
            if res.get("err") != "timeout":
                break
    time.sleep(1.2)
    after = next((w for w in M.r8state().get("wins", []) if w["wid"] == cgid), None)
    live = M.live_ids()
    return {"ok": bool(res.get("ok")) and cgid in live, "target": title, "cgid": cgid,
            "before": before, "after": after, "live_after": live, "switched": switched,
            "nudges": nudge, "res": res, "piles_after": {
                p["title"]: p["ids"] for p in M.r8state().get("piles", [])}}


# ---------------------------------------------------------------- level
def level(n):
    M = wmctl()
    # the sweep below is a hover; teaching is off so a hover lift cannot become a base (round 34)
    cfg_set(levels=True, level_manual=int(n), teach=False)
    M.force_writes()
    time.sleep(0.6)
    M.force_writes()
    time.sleep(0.4)
    cfg_set(teach=True)
    # read the strip windows straight out of CGWindowList (r8state): a retracted strip has
    # negative x, and the level change is a layer change, so x must not be part of the filter
    st = M.r8state()
    tiles = [{"id": w["wid"], "owner": w["owner"], "name": w.get("name", ""),
              "layer": w["layer"], "w": w["w"], "h": w["h"]}
             for w in st.get("wins", [])
             if w.get("on") and w["layer"] in (0, 3) and 60 <= w["w"] <= 340
             and 60 <= w["h"] <= 620 and w["owner"] not in
             ("WindowManager", "Window Server", "Dock", "Notification Center")]
    return {"level_manual": int(n), "tiles": tiles, "hb": hb().get("keeper")}


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "measure"
    a = sys.argv[2:]
    if not os.path.exists(D + "/state.json"):
        print('{"ok": false, "err": "not installed (run ./wmship.sh start)"}')
        raise SystemExit(1)
    if cmd == "resize":
        r = apply_scale(a[0]); print(json.dumps(r, indent=1)); sys.exit(0 if r["ok"] else 1)
    elif cmd == "move":
        cg = 0
        if "--cgid" in a:
            cg = int(a[a.index("--cgid") + 1])
        stage = a[0] if a and not a[0].startswith("-") else "current"
        if stage.startswith("#"):
            cg, stage = int(stage[1:]), "current"
        r = move(stage, cg); print(json.dumps(r, indent=1)); sys.exit(0 if r["ok"] else 1)
    elif cmd == "level":
        r = level(a[0]); print(json.dumps(r, indent=1))
    elif cmd == "measure":
        M = wmctl(); print(json.dumps({"tiles": rail_tiles(), "live": M.live_ids(),
                                       "hb": hb()}, indent=1))
    elif cmd == "state":
        print(json.dumps(state_doc(), indent=1))
    elif cmd == "poses":
        print(json.dumps(poses(), indent=1))
    elif cmd == "warm":
        M = wmctl(); print(json.dumps({"sweeps": M.force_writes(), "hb": hb()}, indent=1))
    elif cmd == "cfg":
        print(json.dumps(cfg_get(), indent=1))
    else:
        raise SystemExit("usage: ctl.py move|resize|level|measure|warm|cfg")
