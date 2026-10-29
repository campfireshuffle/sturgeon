#!/usr/bin/python3
"""ctl.py — the capability side of `work/wmship.sh`: move / resize / level / measure.

Everything here goes through the *payload's own page* (via install.py) or through user-side
observers that only read CGWindowList / AX.  No debugger, no task port for the read side.

  ctl.py move <stage|current|#cgid> [--cgid N]   switch to the stage, then move a window into it
  ctl.py resize <scale> [--teach]                strip rendered scale 0.4 .. 1.5 (1.0 = natural)
  ctl.py teach                                   re-learn every tile's resting pose, now
  ctl.py selfcheck                               is the teach state good enough to offer resize?
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

# One teach pass is a sweep over every tile plus the settle the payload's gate needs before it
# will learn: the expensive half of a resize.  It happens only when the layout is not known yet.
TEACH_SETTLE = 1.2
FAST_TRIES = 2           # bases present and fresh: apply, then re-sweep only if a tile missed
SLOW_TRIES = 4           # the old budget, kept for the path that just re-learned the layout
SELFCHECK_TOL = 0.02     # issue #5: a tile more than 2% off the expected scale is a refusal


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
        with open(NATURAL) as f:
            d = json.load(f)
    except Exception:
        return {}
    return {str(k): v for k, v in (d or {}).items() if isinstance(v, (int, float))}


# ---------------------------------------------------------------- teach (issue #17)
def teach_reason(tiles, nat, rows):
    """Why a teach pass is required before a resize can be trusted, or None when it is not.

    The three reasons the old code taught unconditionally on every resize are all observable:
    a rail tile with no taught base (the payload publishes `hasbase` per pose), and a tile set the
    natural-width record has never seen (the strip re-lays out when the set changes, so widths are
    keyed by window id).  When neither holds, the bases are for this layout and can be reused."""
    ids = [str(t["id"]) for t in tiles]
    if not ids:
        return "no strip tiles on screen"
    if set(ids) != set(nat):
        return "tile set changed (%d live, %d in the natural record)" % (len(ids), len(nat))
    have = {int(r["wid"]) for r in rows if r.get("base")}
    nobase = [int(i) for i in ids if int(i) not in have]
    if nobase:
        return ("%d tile(s) have no taught base: %s"
                % (len(nobase), ", ".join(str(x) for x in nobase)))
    return None


def teach_now(M=None, settle=TEACH_SETTLE):
    """One teach pass: re-learn every rail tile's resting pose and re-record the natural widths
    that go with it.

    Teaching is only allowed at scale 1.0 (the payload gates on it, because a base learned at any
    other scale bakes that scale in), so this releases any applied scale first and leaves the
    strip at 1.0; the caller applies the scale it wants afterwards.  Teaching is switched off again
    before returning: a later sweep must not learn from a hover lift (round 34)."""
    M = M or wmctl()
    t0 = time.time()
    cfg_set(s=1.0, dilate=False, teach=True)
    moves = M.force_writes()
    time.sleep(settle)
    tiles = rail_tiles()
    nat = {str(t["id"]): t["w"] for t in tiles}
    if nat:
        with open(NATURAL, "w") as f:
            json.dump(nat, f, indent=1)
    cfg_set(teach=False)
    have = {int(r["wid"]) for r in poses() if r.get("base")}
    nobase = [int(i) for i in nat if int(i) not in have]
    return {"ok": bool(nat) and not nobase, "moves": moves, "tiles": len(nat),
            "bases": len(nat) - len(nobase), "no_base": nobase,
            "secs": round(time.time() - t0, 2)}


# ---------------------------------------------------------------- resize
def apply_scale(s, tries=None, teach=False):
    """Scale the strip and verify it per tile against each tile's natural width.  The keeper
    applies the scale on every WM pose write, so a tile the WM has not re-emitted yet is caught
    by the next sweep (each sweep is a hover over every tile: user-side mouse moves only).

    The natural-width record is keyed by window id, so a change in the stage set (a stage switch,
    a window closing) used to leave stale entries behind and report `ok: false` while the
    geometry was right (round 32, reporting defect).  It is now refreshed whenever the set of
    tiles differs from the record.

    Issue #17: a full teach pass is the expensive half of a resize, and it is needed only when the
    layout is not already known -- a tile with no base, or a tile set the record has not seen.
    Otherwise the bases are reused and this command only does its measurement sweep.  `teach=True`
    forces the pass (the `resize --teach` / `teach` verbs)."""
    M = wmctl()
    s = round(float(s), 3)
    t0 = time.time()
    tiles = rail_tiles()
    if not tiles:
        return {"s": s, "ok": False, "err": "no strip tiles on screen (reveal the strip first)",
                "tiles": []}
    nat = natural()
    why = "requested" if teach else teach_reason(tiles, nat, poses())
    taught = None
    if why:
        taught = teach_now(M)
        if not taught["ok"]:
            cfg_set(teach=True)
            return {"s": s, "ok": False, "tiles": [], "teach": taught,
                    "err": "teach pass did not produce a base for %d tile(s): %s"
                           % (len(taught["no_base"]),
                              ", ".join(str(x) for x in taught["no_base"]) or "no rail tiles")}
        nat = natural()
    if tries is None:
        tries = SLOW_TRIES if why else FAST_TRIES
    # Teaching is off while this command sweeps (round 34): a hover *lift* is a transient pose the
    # WM restores from its own copy without going through the keeper hook, so a base learned from a
    # lift renders `1.5 x lift` (measured 1.505-1.746).  The base is taught by the strip's own
    # reveal/layout writes, before any pointer input.
    c = cfg_set(s=s, dilate=abs(s - 1.0) > 1e-9, qx=16.0, qy=490.0, teach=False)
    rep = {"s": s, "gen": c["gen"], "tries": 0, "tiles": [], "ok": False,
           "teach": {"needed": bool(why), "reason": why, "passes": 1 if why else 0,
                     "secs": (taught or {}).get("secs", 0.0)}}
    for i in range(tries):
        M.force_writes(passes=1)     # measurement only: every tile written once (see wmctl.py)
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
    rep["secs"] = round(time.time() - t0, 2)
    with open(LAST_RESIZE, "w") as f:
        json.dump(rep, f, indent=1)
    return rep


# ---------------------------------------------------------------- selfcheck (issue #5)
def selfcheck(tiles=None, nat=None, s=None, tol=SELFCHECK_TOL):
    """The resize preflight: is every tile where a working teach gate says it should be?

    A tile's natural width is recorded at scale 1.0, so the drawn width must read `s x natural`
    (`s` is the scale currently applied, 1.0 when none is).  This does not teach and does not
    write the configuration at all: teaching here would hide exactly the quiet failure it is
    meant to detect (a base baked from a hover lift, or a stale base after an OS update), and a
    check that changes the scale could not be "exit with the strip where you found it".
    Measurement is user-side (CGWindowList) only, so one pass costs milliseconds and no pointer
    movement.  The measurement layer is a parameter so this is testable without a WindowManager."""
    if tiles is None:
        tiles = rail_tiles()
    if nat is None:
        nat = natural()
    if s is None:
        c = cfg_get()
        s = float(c.get("s", 1.0)) if c.get("dilate") else 1.0
    s = round(float(s), 3)
    rows = []
    for t in tiles:
        n = nat.get(str(t["id"]))
        rows.append({"id": t["id"], "owner": t.get("owner"), "w": t["w"], "natural": n,
                     "ratio": round(t["w"] / n, 3) if n else None})
    rep = {"ok": False, "s": s, "tol": tol, "tiles": rows, "err": None}
    if not rows:
        rep["err"] = "no strip tiles on screen (reveal the strip first)"
        return rep
    missing = [r["id"] for r in rows if not r["natural"]]
    if missing:
        rep["err"] = ("no natural width on record for tile(s) %s — run: wmship.sh teach"
                      % ", ".join(str(x) for x in missing))
        return rep
    bad = [r for r in rows if abs(r["ratio"] - s) > tol + 1e-9]
    rep["ok"] = not bad
    if bad:
        worst = max(bad, key=lambda r: abs(r["ratio"] - s))
        rep["err"] = ("tile %d measures %.3f x natural, want %.3f ± %.2f (%d of %d tiles off)"
                      % (worst["id"], worst["ratio"], s, tol, len(bad), len(rows)))
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
        rest = [x for x in a if not x.startswith("-")]
        r = apply_scale(rest[0] if rest else 1.0, teach="--teach" in a)
        print(json.dumps(r, indent=1)); sys.exit(0 if r["ok"] else 1)
    elif cmd == "teach":
        r = teach_now()
        cfg_set(teach=True)              # leave the payload able to learn the next layout
        print(json.dumps(r, indent=1)); sys.exit(0 if r["ok"] else 1)
    elif cmd == "selfcheck":
        r = selfcheck()
        print(json.dumps(r, indent=1))
        if not r["ok"]:
            print("selfcheck: resize unavailable — %s" % r["err"], file=sys.stderr)
            I.log("selfcheck: %s" % r["err"])       # the app shows it; the log keeps it
        sys.exit(0 if r["ok"] else 1)
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
        raise SystemExit("usage: ctl.py move|resize|teach|selfcheck|level|measure|warm|cfg")
