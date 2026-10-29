"""wm.py — the consolidated in-WM control surface.

One lldb attach to WindowManager provides all four capabilities that rounds 18-21 proved
separately:

  births  (round 18) a window born for an app that has no window in the current stage is
                     injected into the current stage: at the driver's empty
                     `Array<TransientWindowSetOperation>` call we substitute a 1-element
                     array carrying the newborn's validated `WindowID`.
  move    (round 19) on request the driver's own `Compute.InputModel` is re-pointed at a
                     named stage (`+0x10/+0x18` and `+0x40/+0x48`) so the WM's
                     Compute -> Apply -> placement tail moves a live window between stages.
  on-top  (round 20) while a flush full-size window is frontmost, the strip's per-tile 4x4
                     is replayed at its write site so the tiles never leave the visible
                     pose, and the strip windows are raised inside the WM's transaction.
  resize  (round 21) the strip's rendered size is scaled by composing a screen-space
                     dilation onto the inverse pose the WM writes: W' = D^-1 * W.

The four share one breakpoint set, one `WindowID` census, one injection pool and one
high-water mark of the WM's own array header.

Control files (all under /tmp/wm):
  cfg.json     {"births":bool,"replay":bool,"dilate":bool,"levels":bool,
                "s":float,"qx":16,"qy":490,"gen":int}
  state.json   strip state published by the user-side observer (r21obs): flush, strip_ids,
               rail_now, strip_on, front_x
  pending.txt  windows the births observer saw appear ("<cgid> <owner>")
  req.json     a move/dump request; res.json the WM's answer
  events.log   in-WM event log (same clock as the observers)
  hb.json      counters, written on request (wmctl status)
  bases.bin    learned strip poses, keyed by WM pid
  hdr.bin      the WM's own array header, isa stored slide-normalised
"""
import json
import lldb
import os
import struct
import time

D = "/tmp/wm"
EV = D + "/events.log"
CFG = D + "/cfg.json"
STATE = D + "/state.json"
PENDING = D + "/pending.txt"
REQ = D + "/req.json"
RES = D + "/res.json"
HDRF = D + "/hdr.bin"
BASEF = D + "/bases.bin"
HBF = D + "/hb.json"
ARMF = D + "/arm.json"
SELFF = D + "/self.txt"
os.makedirs(D, exist_ok=True)

ASM = 0x10029BE20        # transient-op chain entry (x20 = self)
DRV = 0x1002A6970        # per-candidate driver: x0 = Array<TransientWindowSetOperation>
COMPUTE = 0x100268598    # op builder
TAGP = 0x1002A6ABC       # the driver's switch value
APPLY = 0x1002A7084      # StageManagerApplyTransientWindowSetOperations
BIRTHLR = 0x1002AC2B0    # return address of the birth caller
IVAR_REG = 0x1005B4640
IVAR_COMP = 0x1005B1E78
WIDMETA = 0x1005A3568
TAIL = [(0x1002A6F4C, "after_apply"), (0x1002A6F54, "after_apply2"),
        (0x1002A6F60, "pre_158164"), (0x1002A6FA0, "pre_27dca8"),
        (0x1002A6FA4, "pre_1d00c0"), (0x1002A6FC0, "pre_251e0"),
        (0x1002A6FE8, "pre_b2c58"), (0x1002A7010, "post_b2c58")]
SLSN = ["SLSTransactionSetWindowTransform3D", "SLSTransactionSetWindowTransform"]

ELEM_WORDS = [0x0000000000000000, 0x001200316F77AE00, 0x0001010000120000,
              0x000000016F000001, 0x4040000000000000, 0x002E006D01010101,
              0xC63F000000160000, 0x4048000000000000, 0x3FF0000000000000,
              0x3FD0000000000000, 0x3FC0000000000000, 0x4014000000000000,
              0x3FD0000000000000, 0x3FF0000000000000, 0x3F50624DD2F1A9FC,
              0x3F50624DD2F1A9FC, 0x0000000000000332, 0x0000000000000000]

KEEP_W = 0x80            # the matrix; sp+0x90 holds the saved x29/x30 -- never write past 0x80
SKY = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"

S = {"slide": 0, "self": 0, "comp": 0, "pool": 0, "slot": 0, "live_hdr": b"",
     "known": {}, "zones": [], "desc_cache": {}, "hits": 0,
     # births (round 18)
     "pending": False, "wid": 0, "widser": 0, "injected": 0, "done": set(),
     "done_cgid": set(), "birth_t0": 0.0, "first": 0.0, "last_scan": 0.0,
     "injections": [], "misses": 0, "natives": 0,
     # move (round 19)
     "mv": {"pending": False, "patch": None, "cur": None, "req": None, "last_dump": 0.0},
     "subjects": {}, "moves": 0,
     # strip (rounds 20/21)
     "taught": {}, "base": {}, "replayed": 0, "scaled": 0, "learned": 0, "tstate": 0.0,
     "ids": set(), "rail_ids": set(), "force": False, "strip_on": False, "front_x": -1.0,
     "levels": False, "level": 3, "leveled": set(), "lvl_t": {}, "lvl_done": {},
     "wrote": {}, "cfg": {"births": True, "replay": True, "dilate": True, "levels": True,
             "level_manual": 0, "s": 1.0, "qx": 16.0, "qy": 490.0, "gen": 0},
     "t_cfg": 0.0, "gen_applied": None, "last_hb": 0.0, "arm_t": 0.0, "bps": []}


# ---------------------------------------------------------------- plumbing
def evt(m):
    try:
        with open(EV, "a") as f:
            f.write("%.3f %s\n" % (time.time(), m))
    except Exception:
        pass


def read_cfg(min_iv=0.0):
    now = time.time()
    if min_iv and now - S["t_cfg"] < min_iv:
        return S["cfg"]
    S["t_cfg"] = now
    try:
        c = json.load(open(CFG))
        if isinstance(c, dict):
            d = dict(S["cfg"])
            d.update(c)
            S["cfg"] = d
    except Exception:
        pass
    return S["cfg"]


def read_state(min_iv=0.02):
    now = time.time()
    if now - S["tstate"] < min_iv:
        return S["force"], S["ids"]
    S["tstate"] = now
    try:
        st = json.load(open(STATE))
    except Exception:
        return S["force"], S["ids"]
    cfg = read_cfg()
    S["force"] = bool(st.get("flush", False)) and bool(cfg.get("replay", True))
    S["ids"] = set(int(x) for x in st.get("strip_ids", []))
    S["rail_ids"] = set(int(x) for x in st.get("rail_now", []))
    S["strip_on"] = bool(st.get("strip_on", False))
    S["front_x"] = float(st.get("front_x", -1))
    return S["force"], S["ids"]


def proc():
    return lldb.debugger.GetSelectedTarget().GetProcess()


def slide():
    if S["slide"]:
        return S["slide"]
    t = lldb.debugger.GetSelectedTarget()
    try:
        for m in t.module_iter():
            if m.GetFileSpec().fullpath.endswith("/MacOS/WindowManager"):
                lo = m.GetObjectFileHeaderAddress().GetLoadAddress(t)
                if lo > 0x100000000:
                    S["slide"] = lo - 0x100000000
    except Exception:
        pass
    return S["slide"]


def rd(a, n):
    e = lldb.SBError()
    d = proc().ReadMemory(a, n, e)
    return d if d and e.Success() else None


def wr(a, b):
    e = lldb.SBError()
    proc().WriteMemory(a, bytes(b), e)
    return e.Success()


def q(d, off):
    return struct.unpack_from("<Q", d, off)[0]


def rv(frame, r):
    v = frame.FindRegister(r)
    return v.GetValueAsUnsigned() if v and v.GetError().Success() else 0


def ok(v):
    return 0x1000 < v < 0x900000000000


def is_wid(v):
    if not ok(v):
        return False
    d = rd(v, 0x18)
    return bool(d) and (q(d, 0) & 0x7FFFFFFFFFFF) == (WIDMETA + slide())


def serial(v):
    d = rd(v, 0x18) if ok(v) else None
    return q(d, 0x10) if d else 0


def desc(addr):
    c = S["desc_cache"].get(addr)
    if c is not None:
        return c
    ci = lldb.debugger.GetCommandInterpreter()
    res = lldb.SBCommandReturnObject()
    t0 = time.time()
    try:
        ci.HandleCommand("expr -l swift -O -- unsafeBitCast(%d, to: AnyObject.self)" % addr, res)
        txt = ((res.GetOutput() or "") or (res.GetError() or "")).strip().replace("\n", " ")
    except Exception as e:
        txt = "<desc error %r>" % (e,)
    S["desc_cache"][addr] = txt
    evt("DESC %#x %.0fms %r" % (addr, (time.time() - t0) * 1000, txt))
    return txt


def obj_desc(addr):
    ci = lldb.debugger.GetCommandInterpreter()
    res = lldb.SBCommandReturnObject()
    ci.HandleCommand("expr -l swift -O -- unsafeBitCast(%d, to: AnyObject.self)" % addr, res)
    return ((res.GetOutput() or "") or (res.GetError() or "")).strip()


def main_frame():
    p = proc()
    th = None
    for i in range(p.GetNumThreads()):
        t = p.GetThreadAtIndex(i)
        try:
            if t.GetQueueName() == "com.apple.main-thread":
                th = t
                break
        except Exception:
            pass
    th = th or p.GetThreadAtIndex(0)
    return th.GetFrameAtIndex(0)


def alloc(n):
    r = main_frame().EvaluateExpression("(void*)malloc(%d)" % n)
    if r.GetError().Fail():
        evt("ALLOC FAIL %s" % r.GetError().GetCString())
        return 0
    return r.GetValueAsUnsigned()


# ---------------------------------------------------------------- census
def band():
    p = proc()
    lst = p.GetMemoryRegions()
    out = []
    for i in range(lst.GetSize()):
        r = lldb.SBMemoryRegionInfo()
        if not lst.GetMemoryRegionAtIndex(i, r):
            continue
        b, e = r.GetRegionBase(), r.GetRegionEnd()
        if r.IsReadable() and 0x7000000000 <= b < 0x8000000000:
            out.append((b, e - b))
    return out


def scan_wids(regions=None):
    p = proc()
    meta = WIDMETA + slide()
    pat = struct.pack("<I", meta & 0xFFFFFFFF)
    out = {}
    for base, size in (regions if regions is not None else (S["zones"] or band())):
        off = 0
        while off < size:
            n = min(0x100000, size - off)
            d = rd(base + off, n)
            if d:
                i = d.find(pat)
                while i >= 0:
                    a = base + off + i
                    if a % 8 == 0:
                        h = rd(a, 0x18)
                        if h and (q(h, 0) & 0x7FFFFFFFFFFF) == meta:
                            ser = q(h, 0x10)
                            if 0 < ser < 0x100000:
                                out[a] = ser
                    i = d.find(pat, i + 1)
            off += n
    return out


def census():
    t0 = time.time()
    per, w = [], {}
    for base, size in band():
        got = scan_wids([(base, size)])
        if got:
            per.append((base, size, len(got)))
            w.update(got)
    S["known"] = w
    S["zones"] = [(b, s) for b, s, n in per]
    evt("CENSUS wids=%d zones=%s %.0fms" % (
        len(w), [(hex(b), n) for b, _, n in per], (time.time() - t0) * 1000))
    return len(w)


def delta_wids():
    t0 = time.time()
    w = scan_wids()
    new = [(a, s) for a, s in w.items() if S["known"].get(a) != s]
    S["known"] = w
    S["last_scan"] = time.time()
    if new:
        evt("DELTA new=%d %s %.0fms" % (len(new), [(hex(a), s) for a, s in new[:6]],
                                        (time.time() - t0) * 1000))
    return new


def pending_cgids():
    out = []
    try:
        for line in open(PENDING).read().split("\n"):
            f = line.split()
            if len(f) >= 2:
                try:
                    out.append((int(f[0]), f[1]))
                except Exception:
                    pass
    except Exception:
        pass
    return out


def identify():
    """(wid, serial, desc, how, cgid) for the newborn, confirmed by the WM's own description
    against a CGWindowID the observer saw appear.  Nothing is guessed."""
    if S["pending"]:
        return 0, 0, "", "", 0
    pend = [(c, o) for c, o in pending_cgids() if c not in S["done_cgid"]]
    if not pend:
        return 0, 0, "", "", 0
    if time.time() - S["last_scan"] < 0.10:
        return 0, 0, "", "", 0
    new = delta_wids()

    def match(cands):
        cands = sorted(cands, key=lambda x: -x[1])
        for a, ser in cands[:6]:
            d = desc(a).lower()
            for cgid, owner in pend:
                if ("(0x%x)" % cgid) in d:
                    return a, ser, d, "desc-cgid:%s(0x%x)" % (owner, cgid), cgid
        return None

    hit = match(new) if new else None
    if hit:
        return hit
    # Fallback (only on a miss, so a normal birth never pays for it): the WindowID may have been
    # allocated in a zone that held none when this session armed.  Re-scan every readable region
    # in the 0x70..0x80 band once and look again.
    t0 = time.time()
    full = scan_wids(band())
    S["known"] = full
    S["zones"] = [(b, z) for b, z in band()]
    hit = match(list(full.items()))
    evt("FULLSCAN wids=%d %.0fms %s" % (len(full), (time.time() - t0) * 1000,
                                        "HIT" if hit else "NOID"))
    if hit:
        return hit
    evt("NOID new=%d pend=%s" % (len(new), pend[:4]))
    return 0, 0, "", "", 0


# ---------------------------------------------------------------- array + hdr
def save_hdr(hdr):
    try:
        b = bytearray(hdr)
        struct.pack_into("<Q", b, 0, q(hdr, 0) - slide())
        open(HDRF, "wb").write(bytes(b))
    except Exception as e:
        evt("HDR SAVE FAIL %r" % (e,))


def load_hdr():
    try:
        b = bytearray(open(HDRF, "rb").read())
        if len(b) != 0x20:
            return b""
        struct.pack_into("<Q", b, 0, q(bytes(b), 0) + slide())
        return bytes(b)
    except Exception:
        return b""


def mk_array(wid):
    hdr = S["live_hdr"]
    if not hdr or len(hdr) != 0x20:
        evt("MK ABORT no live array header")
        return 0
    el = bytearray(0x330)
    for i, w in enumerate(ELEM_WORDS):
        struct.pack_into("<Q", el, 8 * i, w)
    struct.pack_into("<Q", el, 0, wid)
    buf = bytearray(0x20 + 0x330)
    buf[0:0x20] = hdr
    struct.pack_into("<I", buf, 0x08, 0x3F)
    struct.pack_into("<Q", buf, 0x10, 1)
    struct.pack_into("<Q", buf, 0x18, 2)
    buf[0x20:] = el
    a = 0
    if S["pool"]:
        i = S["slot"]
        a = S["pool"] + (i % 8) * 0x350
        S["slot"] = i + 1
    if not a:
        a = alloc(len(buf))
        if not a:
            return 0
    wr(a, bytes(buf))
    chk = rd(a + 0x20, 8)
    if not chk or q(chk, 0) != wid:
        evt("MK ABORT element mismatch")
        return 0
    return a


# ---------------------------------------------------------------- registry
def comp_addr():
    if S["comp"]:
        return S["comp"]
    if not S["self"]:
        return 0
    d = rd(IVAR_COMP + slide(), 8)
    off = q(d, 0) if d else 0
    d2 = rd(S["self"] + off, 8) if off else None
    S["comp"] = q(d2, 0) if d2 else 0
    return S["comp"]


def str_text(w0, w1):
    p = w1 & 0x0000FFFFFFFFFFFF
    if ok(p):
        d = rd(p, 0x60)
        if d:
            for off in (0x20, 0x10, 0x00):
                s = d[off:off + 64].split(b"\x00")[0]
                try:
                    txt = s.decode("utf-8")
                except Exception:
                    continue
                if len(txt) >= 20 and sum(c.isalnum() or c == "-" for c in txt) > 20:
                    return txt
    n = w0 & 0xFF
    if 0 < n <= 15:
        raw = struct.pack("<QQ", w0, w1)
        try:
            return raw[1:1 + n].decode("utf-8")
        except Exception:
            pass
    return "?"


def set_count(sp):
    d = rd(sp, 0x20)
    return int(q(d, 0x10)) if d else 0


def set_members(sp):
    if not ok(sp):
        return []
    txt = obj_desc(sp)
    addrs = []
    for tok in txt.replace("\n", " ").replace(",", " ").split():
        if tok.startswith("0x") and len(tok) > 6:
            try:
                a = int(tok, 16)
            except Exception:
                continue
            if is_wid(a) and a not in addrs:
                addrs.append(a)
    if addrs:
        return addrs
    cnt = set_count(sp)
    blob = rd(sp, 0x20 + 0x20 * (cnt + 8)) or b""
    out = []
    for off in range(0, len(blob) - 8, 8):
        v = q(blob, off)
        if is_wid(v) and v not in out:
            out.append(v)
    return out[:cnt]


def reg_entries():
    p = proc()
    comp = comp_addr()
    if not comp:
        return []
    d = rd(IVAR_REG + slide(), 8)
    off = q(d, 0) if d else 0
    h = rd(comp + off, 0x18) if off else None
    if not h:
        return []
    st = q(h, 0x10)
    sh = rd(st, 0x20)
    if not sh:
        return []
    cnt = int(q(sh, 0x10))
    out = []
    for i in range(min(cnt, 40)):
        e = rd(st + 0x20 + 0x18 * i, 0x18)
        if not e:
            continue
        w0, w1 = q(e, 0), q(e, 8)
        sp = q(e, 0x10)
        out.append({"i": i, "w0": w0, "w1": w1, "set": sp, "mem": set_members(sp),
                    "text": str_text(w0, w1)})
    return out


def cgid_of(wid):
    d = desc(wid)
    i = d.find("(0x")
    if i < 0:
        return 0
    j = d.find(")", i)
    try:
        return int(d[i + 3:j], 16)
    except Exception:
        return 0


def dumpreg(path=None):
    ents = reg_entries()
    lines = ["REG self=%#x comp=%#x n=%d slide=%#x t=%.3f pid=%d" % (
        S["self"], comp_addr(), len(ents), slide(), time.time(), proc().GetProcessID())]
    for e in ents:
        lines.append("SET%d id=%r w=%016x/%016x set=%#x n=%d" % (
            e["i"], e["text"], e["w0"], e["w1"], e["set"], len(e["mem"])))
        for a in e["mem"][:24]:
            lines.append("   %#x ser=%d cgid=%d %r" % (a, serial(a), cgid_of(a), desc(a)))
    txt = "\n".join(lines)
    open(path or (D + "/reg.txt"), "w").write(txt + "\n")
    evt("REGCAP n=%d %s" % (len(ents), path or (D + "/reg.txt")))
    return txt


# ---------------------------------------------------------------- requests
def read_req():
    try:
        r = json.load(open(REQ))
        return r if isinstance(r, dict) else None
    except Exception:
        return None


def write_res(d):
    tmp = RES + ".tmp"
    json.dump(d, open(tmp, "w"))
    os.replace(tmp, RES)


def find_subject(cgid):
    if cgid in S["subjects"]:
        w = S["subjects"][cgid]
        if is_wid(w):
            return w
    for e in reg_entries():
        for a in e["mem"]:
            if cgid_of(a) == cgid:
                S["subjects"][cgid] = a
                return a
    cands = [a for a, _ in delta_wids()]
    if len(cands) < 2:
        cands = [a for a, _ in sorted(S["known"].items(), key=lambda kv: -kv[1])]
    for a in cands[:24]:
        if cgid_of(a) == cgid:
            S["subjects"][cgid] = a
            return a
    return 0


def target_words(req):
    w0 = req.get("w0") or "0"
    w1 = req.get("w1") or "0"
    return (int(w0, 16) if isinstance(w0, str) else int(w0),
            int(w1, 16) if isinstance(w1, str) else int(w1))


def do_move(frame, x0, cnt, req):
    cgid = int(req.get("cgid") or 0)
    w0, w1 = target_words(req)
    if req.get("mode") != "native" and not w0:
        evt("MOVE ABORT no target words")
        req["state"] = "failed"
        json.dump(req, open(REQ, "w"))
        write_res({"ok": False, "error": "no target set id words"})
        return
    wid = find_subject(cgid)
    if not wid:
        evt("MOVE ABORT subject cgid=%d not in registry" % cgid)
        return
    if not is_wid(wid) or not serial(wid):
        evt("MOVE ABORT bad wid %#x" % wid)
        return
    arr = mk_array(wid)
    if not arr:
        return
    S["mv"].update({"pending": True, "patch": {"w0": w0, "w1": w1,
                                               "mode": req.get("mode", "tag1"), "cgid": cgid},
                    "cur": {"cgid": cgid, "wid": wid, "ser": serial(wid), "req": req,
                            "t": time.time(), "applied": None, "tail": []}})
    frame.FindRegister("x0").SetValueFromCString(hex(arr))
    req["state"] = "running"
    json.dump(req, open(REQ, "w"))
    S["moves"] += 1
    evt("MOVE INJECT cgid=%d wid=%#x ser=%d x0 %#x->%#x cnt=%d mode=%s target=%016x/%016x"
        % (cgid, wid, serial(wid), x0, arr, cnt, req.get("mode", "tag1"), w0, w1))


# ---------------------------------------------------------------- breakpoints
def drv_cb(frame, bp_loc, internal_dict):
    try:
        cfg = read_cfg()
        S["hits"] += 1
        x0 = rv(frame, "x0")
        x20 = rv(frame, "x20")
        lr = rv(frame, "lr") - slide()
        if ok(x20) and not S["self"] and rd(x20, 0x10):
            S["self"] = x20
            try:
                open(SELFF, "w").write("%d %#x\n" % (proc().GetProcessID(), x20))
            except Exception:
                pass
            evt("SELF %#x (drv)" % x20)
        d = rd(x0, 0x20) if ok(x0) else None
        cnt = q(d, 0x10) if d else -1
        if not S["live_hdr"] and d and 0 < cnt <= 12:
            S["live_hdr"] = bytes(d)
            save_hdr(bytes(d))
            evt("HDR captured count=%d isa=%#x" % (cnt, q(d, 0)))

        # ---- requests (round 19): move / dump, serviced inside the driver call.
        # The file is the source of truth; a cached request is only kept while a move is in
        # flight, otherwise a finished request would mask every later one.
        req = read_req()
        if req and req.get("state", "new") == "new":
            if req.get("op") in ("move", "probe") and (cnt == 0 or req.get("any_entry")) \
                    and not S["mv"]["pending"]:
                S["mv"]["req"] = req
                do_move(frame, x0, cnt, req)
                return False
            if req.get("op") == "dump":
                if time.time() - S["mv"]["last_dump"] > 0.3:
                    S["mv"]["last_dump"] = time.time()
                    try:
                        path = req.get("path") or (D + "/reg.txt")
                        dumpreg(path)
                        req["state"] = "done"
                        json.dump(req, open(REQ, "w"))
                        write_res({"ok": True, "op": "dump", "path": path, "t": time.time()})
                    except Exception as e:
                        evt("DUMP EXC %r" % (e,))
                return False

        if S["mv"]["pending"]:
            return False

        # ---- births (round 18)
        if not cfg.get("births", True):
            return False
        if lr != BIRTHLR:
            return False
        if not S["birth_t0"] or time.time() - S["birth_t0"] > 6.0:
            S["birth_t0"] = time.time()
            S["first"] = 0.0
            S["pending"] = False
            evt("BIRTH t0 (count=%d)" % cnt)
        if cnt > 0:
            e = rd(x0 + 0x20, 8)
            w = q(e, 0) if e else 0
            if is_wid(w):
                S["natives"] += 1
                evt("NATIVE WM op carries %#x serial=%d" % (w, serial(w)))
                S["done"] = S["done"] | {serial(w)}
                for c, o in pending_cgids():
                    if ("(0x%x)" % c) in desc(w):
                        S["done_cgid"] = S["done_cgid"] | {c}
            return False
        if cnt < 0:
            return False
        do_birth(frame, x0, cnt)
    except Exception as e:
        evt("DRV EXC %r" % (e,))
    return False


def do_birth(frame, x0, cnt):
    if S["pending"]:
        return False
    now = time.time()
    if not S["first"]:
        S["first"] = now
    if now - S["first"] > 6.0:
        evt("GIVEUP birth older than 6s")
        return False
    wid, ser, d, how, cgid = identify()
    if not wid:
        S["misses"] += 1
        return False
    if ser in S["done"]:
        return False
    if not is_wid(wid) or not ser:
        evt("REJECT operand failed validation %#x ser=%s" % (wid, ser))
        return False
    arr = mk_array(wid)
    if not arr:
        return False
    S.update({"pending": True, "wid": wid, "widser": ser, "injected": S["injected"] + 1,
              "done": S["done"] | {ser}, "done_cgid": S["done_cgid"] | {cgid}})
    frame.FindRegister("x0").SetValueFromCString(hex(arr))
    elapsed = (time.time() - S["birth_t0"]) * 1000 if S["birth_t0"] else -1
    S["injections"].append((time.time(), wid, ser, how))
    evt("INJECT #%d x0 %#x -> %#x count %d->1 wid=%#x serial=%d how=%s +%.0fms"
        % (S["injected"], x0, arr, cnt, wid, ser, how, elapsed))
    return True


def compute_cb(frame, bp_loc, internal_dict):
    try:
        cfg = read_cfg()
        x0 = rv(frame, "x0")
        x20 = rv(frame, "x20")
        d = rd(x20, 0x88) if ok(x20) else None

        # ---- move: re-point the driver's own model at the target stage
        mv = S["mv"]
        if mv["pending"] and mv["patch"] and mv["cur"] and ok(x20):
            words = [q(d, i * 8) for i in range(17)] if d else []
            evt("COMPUTE x0=%#x x20=%#x model+10=%#x|%#x +40=%#x|%#x +50=%#x" % (
                x0, x20, q(d, 0x10), q(d, 0x18), q(d, 0x40), q(d, 0x48), q(d, 0x50))
                if d else "COMPUTE unreadable model")
            if mv["patch"]["mode"] in ("tag1", "tag0"):
                w0, w1 = mv["patch"]["w0"], mv["patch"]["w1"]
                wr(x20 + 0x10, struct.pack("<QQ", w0, w1))
                wr(x20 + 0x40, struct.pack("<QQ", w0, w1))
                evt("PATCH %s +10/+40 %016x/%016x" % (mv["patch"]["mode"], w0, w1))
                mv["patch"]["done"] = True
            mv["cur"]["model"] = words

        # ---- births: second net, a validated operand never reaches Compute as a non-WindowID
        if not cfg.get("births", True):
            return False
        if S["pending"]:
            if not is_wid(x0) and S.get("wid"):
                frame.FindRegister("x0").SetValueFromCString(hex(S["wid"]))
                evt("GUARD x0 not-a-WindowID -> %#x" % S["wid"])
            S["pending"] = False
        if d and S.get("wid") and (x0 == S["wid"] or is_wid(x0)):
            evt("BCOMPUTE x0=%#x%s model+10=%#x|%#x" % (
                x0, " [our wid]" if x0 == S["wid"] else "", q(d, 0x10), q(d, 0x18)))
    except Exception as e:
        evt("COMPUTE EXC %r" % (e,))
    return False


def apply_cb(frame, bp_loc, internal_dict):
    try:
        p = proc()
        x0 = rv(frame, "x0")
        d = rd(x0, 0x20) if ok(x0) else None
        if not d:
            return False
        cnt = q(d, 0x10)
        ops = []
        for i in range(min(int(cnt), 8)):
            e = rd(x0 + 0x20 + 0x20 * i, 0x20)
            if not e:
                continue
            w0, w1, pl = q(e, 0), q(e, 8), q(e, 0x10)
            tag = struct.unpack_from("<b", e, 0x18)[0]
            ops.append({"tag": tag, "w0": w0, "w1": w1, "pl": pl})
        evt("APPLY ops=%d %s" % (cnt, " | ".join(
            "tag=%d w0=%#x pl=%#x" % (o["tag"], o["w0"], o["pl"]) for o in ops)))
        mv = S["mv"]
        if mv["pending"] and mv["cur"]:
            req = mv["cur"].get("req") or {}
            mv["cur"]["applied"] = ops
            write_res({"ok": True, "op": "move", "cgid": mv["cur"]["cgid"],
                       "wid": hex(mv["cur"]["wid"]), "ops": ops, "t": time.time(),
                       "patch": "done" if (mv["patch"] or {}).get("done") else "none"})
            req["state"] = "done"
            try:
                json.dump(req, open(REQ, "w"))
            except Exception:
                pass
            mv["pending"] = False
            mv["req"] = None
        if S["pending"] and any(o["pl"] == S.get("wid") for o in ops):
            evt("INJECT APPLIED wid=%#x" % S["wid"])
            S["pending"] = False
    except Exception as e:
        evt("APPLY EXC %r" % (e,))
    return False


def asm_cb(frame, bp_loc, internal_dict):
    try:
        x20 = rv(frame, "x20")
        if x20 and x20 != S["self"] and ok(x20) and rd(x20, 8):
            S["self"] = x20
            evt("SELF %#x (asm)" % x20)
    except Exception:
        pass
    return False


def tagp_cb(frame, bp_loc, internal_dict):
    try:
        if S["mv"]["cur"] or S.get("wid"):
            x19 = rv(frame, "x19")
            e = rd(x19, 8) if ok(x19) else None
            w = q(e, 0) if e else 0
            evt("TAGP case=%d elem=%s" % (rv(frame, "x0") & 0xFFFFFFFF,
                                          ("wid=%#x" % w) if is_wid(w) else hex(w)))
    except Exception:
        pass
    return False


TAILNAMES = {a: nm for a, nm in TAIL}


def tail_cb(frame, bp_loc, internal_dict):
    try:
        a = bp_loc.GetAddress().GetFileAddress()
        evt("TAIL %s" % TAILNAMES.get(a, "tail@%#x" % a))
        if S["mv"]["cur"]:
            S["mv"]["cur"].setdefault("tail", []).append(TAILNAMES.get(a, "?"))
    except Exception:
        pass
    return False


# ---------------------------------------------------------------- strip keeper
def _is_identity(d):
    m = struct.unpack("<16d", d)
    ident = (1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0)
    return all(abs(a - b) < 1e-9 for a, b in zip(m, ident))


def _mat_scale(m, s, qx, qy):
    """W' = D^-1 . W: rows 0/1 x 1/s, translation += (1-1/s)*pivot*rows 0,1."""
    se = 1.0 / s
    dx = (1.0 - se) * qx
    dy = (1.0 - se) * qy
    o = list(m)
    w0, w1, w3 = m[0:4], m[4:8], m[12:16]
    o[0:4] = [se * v for v in w0]
    o[4:8] = [se * v for v in w1]
    o[12:16] = [dx * w0[j] + dy * w1[j] + w3[j] for j in range(4)]
    return o


def _save_bases():
    try:
        b = {str(k): v.hex() for k, v in S["base"].items()}
        json.dump({"pid": proc().GetProcessID(), "bases": b}, open(BASEF, "w"))
    except Exception:
        pass


def _load_bases():
    try:
        o = json.load(open(BASEF))
        if o.get("pid") == proc().GetProcessID():
            S["base"] = {int(k): bytes.fromhex(v) for k, v in o["bases"].items()}
            evt("BASES loaded %d" % len(S["base"]))
    except Exception:
        pass


def keeper_cb(frame, bp_loc, internal_dict):
    try:
        S["n"] = S.get("n", 0) + 1
        wid = rv(frame, "x1")
        p = rv(frame, "x2")
        txn = rv(frame, "x0")
        if not ok(p):
            return False
        cfg = read_cfg()
        force, ids = read_state()
        # ---- round 20: replay the learned visible pose while a flush window is up
        base_ok = True
        pf = S.get("prevforce")
        if force != pf:
            S["prevforce"] = force
            if S.get("nrep", 0) < 60:
                S["nrep"] = S.get("nrep", 0) + 1
                evt("FORCE %d (was %s) wid=%d taught=%d ids=%d"
                    % (1 if force else 0, pf, wid, len(S["taught"]), len(ids)))
        if force:
            # The pose learned while the strip was legitimately out is the same object as the
            # dilation base; `taught` (gated on a clearly non-flush front window) wins when it
            # exists, `base` (persisted per WM pid) covers the first flush after an lldb restart.
            pose = S["taught"].get(wid) or S["base"].get(wid)
            if wid in ids and pose:
                d0 = rd(p, 8)
                wr(p, pose)
                S["replayed"] += 1
                if S.get("nrep2", 0) < 40:
                    S["nrep2"] = S.get("nrep2", 0) + 1
                    evt("REPLAY wid=%d wm_wrote=%s" % (wid, d0.hex() if d0 else "-"))
            else:
                base_ok = False
        else:
            if S["strip_on"] and S["front_x"] > 60:
                d = rd(p, KEEP_W)
                if d:
                    S["taught"][wid] = bytes(d)
                    S["learned"] += 1
        # ---- levels: while a flush window is up the strip must draw *above* it (round 20);
        # `level_manual` lets the control surface raise the strip for a click without any
        # debugger interrupt.  Both are applied per window, on that window's own writes.
        want = 0
        if wid in ids and (force or int(cfg.get("level_manual", 0) or 0) == 3):
            want = 3
        if wid in ids and S["lvl_done"].get(wid, 0) != want:
            try:
                frame.EvaluateExpression(
                    "(int)SLSTransactionSetWindowLevel(%d, %d, %d)" % (txn, wid, want))
                S["lvl_done"][wid] = want
                if S.get("nlev", 0) < 80:
                    S["nlev"] = S.get("nlev", 0) + 1
                    evt("LEVEL %d wid=%d" % (want, wid))
            except Exception as e:
                evt("LEVEL ERR %r" % (e,))
        # ---- round 21: the committed pose is a dilation of the *learned natural* pose.
        # Dilating the buffer the WM just wrote compounds (some windows keep their matrix
        # buffer between commits), so the base is captured only while the strip is at 1:1 -
        # or from a replayed pose, which is the visible 1:1 pose - and every commit is
        # computed from that base.  Idempotent: N writes give the same pose, not N x scale.
        s = float(cfg.get("s", 1.0))
        if wid in ids:
            d = rd(p, KEEP_W)
            if d:
                wrote = S.setdefault("wrote", {})
                mine = wrote.get(wid)                     # the value we last committed
                # Learn the natural pose only from a write that is *not* ours: some windows keep
                # their matrix buffer between commits, so a buffer that still holds our value
                # would otherwise be learned back as if it were the WM's own pose (that is what
                # made a scale compound: 0.59 applied to a 0.59 pose).
                if base_ok and (abs(s - 1.0) < 1e-9 or force) and bytes(d) != mine:
                    S["base"][wid] = bytes(d)
                    if len(S["base"]) % 4 == 1:
                        _save_bases()
                b = S["base"].get(wid)
                if wid in S["rail_ids"] and abs(s - 1.0) < 1e-9:
                    # back to 1:1: put the natural pose back, do not just stop writing
                    if mine and b and bytes(d) != b:
                        wr(p, b)
                        wrote[wid] = b
                        S["scaled"] += 1
                elif cfg.get("dilate", True) and wid in S["rail_ids"] \
                        and abs(s - 1.0) > 1e-9 and not _is_identity(b if b else bytes(d)):
                    # A window the WM draws at its natural size has an identity pose (round 21
                    # §5): it is an icon-like rail item, not a transformed tile, and scaling it
                    # would move it off its own frame.
                    src = b if b else bytes(d)
                    out = struct.pack("<16d", *_mat_scale(list(struct.unpack("<16d", src)), s,
                                                          float(cfg.get("qx", 16.0)),
                                                          float(cfg.get("qy", 490.0))))
                    wr(p, out)
                    wrote[wid] = out
                    S["scaled"] += 1
        # ---- a scale/level request is applied here, from the WM's own transaction, on the
        # next layout write.  No `process interrupt` is involved.
        gen = S["cfg"].get("gen")
        if gen is not None and gen != S["gen_applied"] and S["rail_ids"]:
            S["gen_applied"] = gen
            t0 = time.time()
            try:
                lvl = 3 if (force or int(S["cfg"].get("level_manual", 0) or 0) == 3) else 0
                r = apply_scaled(S["rail_ids"], s, float(S["cfg"].get("qx", 16.0)),
                                 float(S["cfg"].get("qy", 490.0)), frame, lvl)
                for wid in S["rail_ids"]:
                    S["lvl_done"][wid] = lvl
                zero = [int(i) for i in (S["cfg"].get("level_zero") or [])]
                if zero:
                    frame.EvaluateExpression(_level_block(zero, 0))
                    evt("LEVEL0 %s" % zero)
                evt("APPLYCFG gen=%s %s %.0fms" % (gen, r, (time.time() - t0) * 1000))
                S["scaled"] += 1
            except Exception as e:
                evt("APPLYCFG ERR %r" % (e,))
        now = time.time()
        if now - S["last_hb"] > 1.0:
            S["last_hb"] = now
            evt("KEEP force=%d wid=%d n=%d replayed=%d scaled=%d taught=%d ids=%d"
                % (1 if force else 0, wid, S["n"], S["replayed"], S["scaled"],
                   len(S["taught"]), len(ids)))
            write_hb()
    except Exception as e:
        evt("KEEP ERR %r" % (e,))
    return False


def write_hb():
    try:
        o = {"t": time.time(), "pid": S.get("pid") or 0, "armed": True,
             "births": {"injected": S["injected"], "misses": S["misses"],
                        "natives": S["natives"], "cgids": sorted(S["done_cgid"])[-6:]},
             "move": {"moves": S["moves"], "pending": S["mv"]["pending"]},
             "strip": {"n": S.get("n", 0), "replayed": S["replayed"], "scaled": S["scaled"],
                       "lvl_done": len(S.get("lvl_done") or {}),
                       "taught": len(S["taught"]), "base": len(S["base"]),
                       "force": S["force"], "strip_on": S["strip_on"],
                       "ids": len(S["ids"]), "rail": len(S["rail_ids"]),
                       "leveled": len(S["leveled"]), "s": S["cfg"].get("s"),
                       "gen_applied": S["gen_applied"]},
             "self": S["self"], "comp": S["comp"], "slide": S["slide"], "bps": S["bps"]}
        tmp = HBF + ".tmp"
        json.dump(o, open(tmp, "w"))
        os.replace(tmp, HBF)
    except Exception:
        pass


# ---------------------------------------------------------------- apply scale
def _apply_many_block(items, level=None):
    n = len(items)
    lvl = -1 if level is None else int(level)
    ids = ",".join(str(int(w)) for w, _ in items)
    rows = ",".join("{" + ",".join(repr(float(v)) for v in m) + "}" for _, m in items)
    return ('(int)({ int res = -1;'
            'typedef void *(*Cr_t)(int);'
            'typedef int (*Set_t)(void*, unsigned int, const double*);'
            'typedef int (*Lv_t)(void*, unsigned int, int);'
            'typedef int (*Comm_t)(void*, int);'
            'void *h = (void*)dlopen("%s", 2);'
            'if (h) {'
            ' Cr_t cr = (Cr_t)(void*)dlsym(h, "SLSTransactionCreate");'
            ' Set_t st = (Set_t)(void*)dlsym(h, "SLSTransactionSetWindowTransform3D");'
            ' Lv_t lv = (Lv_t)(void*)dlsym(h, "SLSTransactionSetWindowLevel");'
            ' Comm_t cm = (Comm_t)(void*)dlsym(h, "SLSTransactionCommit");'
            ' int cid = ((int(*)(void))(void*)dlsym(h, "CGSMainConnectionID"))();'
            ' if (cr && st && cm) { void *t = cr(cid); if (t) {'
            '  unsigned ids[%d] = {%s};'
            '  double mm[%d][16] = {%s};'
            '  int bad = 0;'
            '  for (int i = 0; i < %d; i++) bad += st(t, ids[i], mm[i]);'
            '  if (lv && %d >= 0) for (int i = 0; i < %d; i++) bad += lv(t, ids[i], %d);'
            '  int z = cm(t, 1); res = bad * 100 + z;'
            ' } } }'
            'res; })') % (SKY, n, ids, n, rows, n, lvl, n, lvl)


def _level_block(ids, level):
    sid = ",".join(str(int(i)) for i in ids)
    n = len(ids)
    return ('(int)({ int res=-1;'
            'typedef void *(*Cr_t)(int); typedef int (*Lv_t)(void*, unsigned int, int);'
            'typedef int (*Comm_t)(void*, int);'
            'void *h=(void*)dlopen("%s",2);'
            'if (h) { Cr_t cr=(Cr_t)(void*)dlsym(h,"SLSTransactionCreate");'
            ' Lv_t lv=(Lv_t)(void*)dlsym(h,"SLSTransactionSetWindowLevel");'
            ' Comm_t cm=(Comm_t)(void*)dlsym(h,"SLSTransactionCommit");'
            ' int cid=((int(*)(void))(void*)dlsym(h,"CGSMainConnectionID"))();'
            ' if (cr && lv && cm) { void *t=cr(cid); if (t) {'
            '  unsigned ids[%d]={%s}; int bad=0;'
            '  for (int i=0;i<%d;i++) bad+=lv(t, ids[i], %d);'
            '  int z=cm(t,1); res=bad*100+z; } } }'
            'res; })') % (SKY, n, sid, n, int(level))


def _frame():
    return proc().GetSelectedThread().GetFrameAtIndex(0)


def apply_many(items):
    r = _frame().EvaluateExpression(_apply_many_block(items))
    return r.GetValue(), (r.GetError().GetCString() if r.GetError().Fail() else "")


def apply_scaled(ids, s, qx, qy, frame=None, level=None):
    """Push the dilated pose for every rail window through the WM's own SkyLight transaction -
    one commit, every window, whether or not the WM re-emits that window's pose.  This is
    round 21's apply path; it runs inside a breakpoint callback (so there is a valid frame and
    a live transaction) instead of interrupting the process from outside."""
    items = []
    for wid in sorted(ids):
        b = S["base"].get(wid)
        if not b:
            continue
        items.append((wid, _mat_scale(list(struct.unpack("<16d", b)), s, qx, qy)))
    if not items:
        return "no base"
    f = frame or _frame()
    r = f.EvaluateExpression(_apply_many_block(items, level))
    v = r.GetValue()
    err = r.GetError().GetCString() if r.GetError().Fail() else ""
    for wid, m in items:
        S.setdefault("wrote", {})[wid] = struct.pack("<16d", *m)
    return "applied %d s=%s -> %s %s" % (len(items), s, v, err or "")


def apply_cfg():
    """Called from the FIFO after `process interrupt`: push the cfg's current scale."""
    cfg = read_cfg(0)
    read_state(0)
    s = float(cfg.get("s", 1.0)) if cfg.get("dilate", True) else 1.0
    qx, qy = float(cfg.get("qx", 16.0)), float(cfg.get("qy", 490.0))
    t0 = time.time()
    r = apply_scaled(S["rail_ids"], s, qx, qy)
    evt("APPLYCFG gen=%s s=%s %s bases=%d %.0fms" % (
        cfg.get("gen"), s, r, len(S["base"]), (time.time() - t0) * 1000))
    S["gen_applied"] = cfg.get("gen")
    write_hb()
    return r


def level(level=3, which="rail"):
    """Raise/lower the strip windows with our own transaction (same process as the WM)."""
    read_state(0)
    ids = sorted(S["rail_ids"]) if which == "rail" else [int(x) for x in which]
    n = len(ids)
    sid = ",".join(str(i) for i in ids)
    expr = ('(int)({ int res=-1;'
            'typedef void *(*Cr_t)(int); typedef int (*L_t)(void*, unsigned int, int);'
            'typedef int (*Comm_t)(void*, int);'
            'void *h=(void*)dlopen("%s",2);'
            'if (h) { Cr_t cr=(Cr_t)(void*)dlsym(h,"SLSTransactionCreate");'
            ' L_t lv=(L_t)(void*)dlsym(h,"SLSTransactionSetWindowLevel");'
            ' Comm_t cm=(Comm_t)(void*)dlsym(h,"SLSTransactionCommit");'
            ' int cid=((int(*)(void))(void*)dlsym(h,"CGSMainConnectionID"))();'
            ' if (cr && lv && cm) { void *t=cr(cid); if (t) {'
            '  unsigned ids[%d]={%s}; int bad=0;'
            '  for (int i=0;i<%d;i++) bad+=lv(t, ids[i], %d);'
            '  int z=cm(t,1); res=bad*100+z; } } }'
            'res; })') % (SKY, n, sid, n, int(level))
    r = _frame().EvaluateExpression(expr)
    evt("LEVEL %s %s -> %s" % (level, ids, r.GetValue()))
    return "level %s %s -> %s" % (level, ids, r.GetValue())


# ---------------------------------------------------------------- arm
def load_self():
    try:
        pid, hx = open(SELFF).read().split()
        if int(pid) == proc().GetProcessID():
            S["self"] = int(hx, 16)
    except Exception:
        pass
    return S["self"]


def arm():
    t = lldb.debugger.GetSelectedTarget()
    t.DeleteAllBreakpoints()
    bps = []

    def addr_bp(a, cb, nm):
        b = t.BreakpointCreateByAddress(a + slide())
        b.SetAutoContinue(True)
        b.SetScriptCallbackFunction(cb)
        bps.append(nm)

    for a, cb, nm in ((DRV, "wm.drv_cb", "DRV"), (COMPUTE, "wm.compute_cb", "COMPUTE"),
                      (APPLY, "wm.apply_cb", "APPLY"), (TAGP, "wm.tagp_cb", "TAGP"),
                      (ASM, "wm.asm_cb", "ASM")):
        addr_bp(a, cb, nm)
    for a, nm in TAIL:
        addr_bp(a, "wm.tail_cb", "TAIL_" + nm)
    for nm in SLSN:
        b = t.BreakpointCreateByName(nm)
        if b.GetNumLocations() == 0:
            continue
        b.SetAutoContinue(True)
        b.SetScriptCallbackFunction("wm.keeper_cb")
        bps.append(nm)

    load_self()
    S["live_hdr"] = load_hdr()
    if S["live_hdr"]:
        evt("HDR restored from disk isa=%#x" % q(S["live_hdr"], 0))
    try:
        S["pool"] = alloc(0x350 * 8)
        evt("POOL %#x" % (S["pool"] or 0))
    except Exception as e:
        evt("POOL FAIL %r" % (e,))
    try:
        census()
    except Exception as e:
        evt("CENSUS FAIL %r" % (e,))
    _load_bases()
    read_cfg(0)
    read_state(0)
    S["pid"] = proc().GetProcessID()
    S.update({"pending": False, "birth_t0": 0.0, "hits": 0, "first": 0.0, "slot": 0,
              "mv": {"pending": False, "patch": None, "cur": None, "req": None,
                     "last_dump": 0.0}, "arm_t": time.time(), "bps": bps})
    try:
        json.dump({"pid": proc().GetProcessID(), "slide": slide(), "bps": bps,
                   "t": time.time()}, open(ARMF, "w"))
    except Exception:
        pass
    write_hb()
    evt("ARMED slide=%#x pid=%d bps=%d zones=%d base=%d" % (
        slide(), proc().GetProcessID(), len(bps), len(S["zones"]), len(S["base"])))
    return "armed slide=%#x bps=%d" % (slide(), len(bps))


def status():
    """Write a fresh hb.json from the in-memory counters (no memory reads: callable while the
    WM is running) and print it on one line."""
    write_hb()
    read_cfg(0)
    print("WM_STATUS " + json.dumps({"pid": S.get("pid"), "slide": hex(slide()),
                                    "self": hex(S["self"]), "bps": len(S["bps"]),
                                    "injected": S["injected"], "moves": S["moves"],
                                    "replayed": S["replayed"], "scaled": S["scaled"],
                                    "taught": len(S["taught"]), "base": len(S["base"])}))
    return "ok"


def cache():
    """Diagnostic: which strip windows have a learned pose / a level raise right now."""
    read_state(0)
    print("WM_CACHE " + json.dumps({
        "ids": sorted(S["ids"]), "rail": sorted(S["rail_ids"]),
        "taught": sorted(S["taught"].keys()), "base": sorted(S["base"].keys()),
        "leveled": sorted(S["leveled"]), "force": S["force"], "strip_on": S["strip_on"],
        "front_x": S["front_x"], "replayed": S["replayed"], "n": S.get("n", 0)}))
    return "ok"
