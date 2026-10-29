#!/usr/bin/python3
"""install.py — install / doctor / status / uninstall the Stage Manager payload with no debugger.

    doctor [--wm-binary PATH] [--json] [--mode pristine|armed]
                                        resolve every site and validate it live, in one of two
                                        explicit modes: a pristine WindowManager (every site still
                                        holds the on-disk image's bytes) or our own armed install
                                        (every site holds the stub recorded in backup.json, each
                                        stub lands in the recorded island, and the running body is
                                        the payload image on disk).  Refuses if anything is
                                        unresolved, ambiguous or inconsistent.
    pristine                             every site still holds the on-disk image's own bytes
    install                              doctor, then allocate + write + patch the six sites
    status                               build, armed/disarmed, capabilities, debugger, helper
    uninstall                            restore every site byte-exactly, free the allocations
    hb | log | counters | cfg <json> | req <json> | rd <sym> <n> | find
                                        the in-payload control plane used by wmship.sh

No address of the patched code is a constant in this file.  The six sites come from
`wmlocate.py` (next to this tree), which derives them from the binary's content and cross-references
and caches them in `sites.json` under `CFBundleVersion|sha256(__TEXT)` — in the tree for a checkout,
in `~/Library/Application Support/Sturgeon/` for an installed app.  The two object-layout addresses
the payload needs (the WindowID / WindowIDTable class metadata) come from the build profile in
`profile.json`, which is *verified against the live process* here before a single byte
is written: the profile's isa must agree with the WM's own table serials, and its ivar-offset
globals must read as small aligned offsets.  A profile that does not verify is a refusal.
"""
import hashlib
import json
import os
import shlex
import struct
import subprocess
import sys
import tempfile
import time

# Every path below comes from wmlayout, the one root-resolution function: this file is always at
# <root>/wmship/install.py, and <root> is either the development tree (work/) or
# Sturgeon.app/Contents/Resources/wmship.  Nothing is derived from the cwd or a repo constant.
_HERE = os.path.dirname(os.path.realpath(__file__))
_ROOT = os.path.dirname(_HERE)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)                   # wmlocate.py lives at <root>/
import wmlayout as LAYOUT                       # noqa: E402

L = LAYOUT.layout()
W = L["wmship"]
WORK = L["root"]
PY = L["python"]
ASROOT = L["asroot"]
WMLOCATE = L["wmlocate"]
SITES_JSON = L["sites"]
PROFILE = L["profile"]
WM_LIVE = "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
SKYLIGHT = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
WMX = L["wmx"]
WMCLS = L["wmcls"]
WMHB = L["wmhb"]

D = L["runtime"]
STATE = D + "/state.json"
BAK = D + "/backup.json"
MAP = D + "/map.txt"
LOG = D + "/install.log"

# Scratch files clang needs (the symbol resolver).  D is the daemon's directory and is owned by
# root once the daemon has run; `doctor` and `resolve` are also invoked as the console user, so
# they must never write there (round 34: PermissionError on /tmp/wmship/symres.c made `doctor`
# unusable for exactly the user the tool ships to).  Use a per-uid scratch directory instead.
SCRATCH = os.path.join(tempfile.gettempdir(), "wmship-%d" % os.getuid())

SITE_NAMES = ("birth", "birth2", "birthE", "compute", "keeper3d", "keeper2d")
PACIBSP = 0xD503237F
MOV_X1_X30 = 0xAA1E03E1          # mov x1, x30
MOV_X30_X1 = 0xAA0103FE          # mov x30, x1
DIRECT_REACH = 0x7FFFFFC         # |b| relocation range, bytes
CFG_DEFAULT = {"births": True, "replay": True, "dilate": False, "levels": True,
               "level_manual": 0, "s": 1.0, "qx": 16.0, "qy": 490.0, "gen": 1,
               "use_desc": False, "widcg": True, "retain": True, "probe": False,
               "dump_model": False}

SY = None
PID = 0
DRIVER = 0                       # file VA of the driver entry (== the birthE site)
COMPUTE_CALLEE = 0               # file VA of the compute callee, decoded from the compute site
SITES = []                       # filled by prepare()


class Refuse(Exception):
    pass


# ---------------------------------------------------------------- shell / root
def sh(c, t=60):
    r = subprocess.run(["/bin/zsh", "-c", c], capture_output=True, text=True, timeout=t)
    return r.stdout.strip(), r.stderr.strip(), r.returncode


def root(c, t=120):
    return root_in(W, c, t)


def root_in(d, c, t=120):
    # the command is run by the NOPASSWD helper, whose path is the bundled one in an app install;
    # quote it because an app can live under a path with spaces
    if os.geteuid() == 0:
        return sh("cd %s && %s" % (d, c), t)
    return sh("sudo -n %s -c %s" % (shlex.quote(ASROOT),
                                    shlex.quote("cd %s && %s" % (d, c))), t)


def log(m):
    line = "%.3f %s\n" % (time.time(), m)
    for path, mkdir in ((LOG, D), (SCRATCH + "/install.log", SCRATCH)):
        try:
            if not os.path.isdir(mkdir):
                raise OSError("no dir")

            with open(path, "a") as f:
                f.write(line)
            return
        except Exception:
            continue


def wmx(*a):
    return root("%s %s" % (shlex.quote(WMX), " ".join(str(x) for x in a)))


# ---------------------------------------------------------------- site resolution
def locate(wm_binary=None, slide=None):
    """The six sites from wmlocate (content + cross-reference), cached in sites.json."""
    cmd = [PY, WMLOCATE, wm_binary or "live", "--sites", SITES_JSON, "--quiet"]
    # the SkyLight addresses are unslid cache VAs; --slide auto asks a throwaway dyld for this
    # boot's cache slide, which is the same in every process (no task port, no target contact)
    cmd += ["--slide", "auto"] if slide is None else ["--slide", "auto", "--wm-slide", hex(slide)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    LAYOUT.adopt(SITES_JSON)          # a root-run doctor must not leave a cache the user cannot write
    try:
        res = json.loads(r.stdout)
    except Exception:
        raise Refuse("wmlocate produced no JSON (exit %d): %s"
                     % (r.returncode, (r.stderr or r.stdout).strip()[:400]))
    return res, r.returncode


def file_sites(wm_binary=None, slide=None):
    """Resolved file VAs + build identity, or Refuse with wmlocate's own named refusals."""
    res, rc = locate(wm_binary, slide)
    if not res.get("ok"):
        why = "; ".join("%s: %s" % (x.get("site"), (x.get("why") or "").replace("\n", " "))
                        for x in res.get("refusals") or []) or "unresolved: %s" % res.get("missing")
        raise Refuse("sites unresolved — %s" % why[:700])
    img = res["images"]["WindowManager"]
    sites = {k: int(v["file_va"]) for k, v in res["sites"].items()}
    keepers = {k: (int(v["file_va"]), v.get("live_va")) for k, v in res["sites"].items()
               if k.startswith("keeper")}
    return dict(sites=sites, keepers=keepers, build=img.get("build"),
                text_sha=img.get("text_sha256"), cache=res.get("cache"),
                slide=res.get("slide"), images=res["images"], refusals=res.get("refusals"),
                raw=res)


def load_profile(key):
    try:
        d = json.load(open(PROFILE))
    except Exception:
        return None
    return (d.get("builds") or {}).get(key)


def _json_file(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


# ---------------------------------------------------------------- words / memory helpers
def find():
    out, err, rc = wmx("find")
    if rc != 0:
        if "password" in err:
            raise Refuse("no root via %s (is %s in place? run the bundled setup.sh)"
                         % (ASROOT, LAYOUT.sudoers_path()))
        raise Refuse("WindowManager not running: %s" % (err.strip() or out.strip()))
    d = {}
    for tok in out.split():
        k, _, v = tok.partition("=")
        d[k] = int(v, 0)
    return d


def rb(at, n):
    out, err, rc = wmx("rd", hex(at), str(n))
    b = []
    for line in out.split("\n"):
        if not line.startswith("0x"):
            continue
        for p in line.split("|")[0].split()[1:]:
            if len(p) == 2:
                try:
                    b.append(int(p, 16))
                except ValueError:
                    pass
    return bytes(b[:n])


def words(at, n):
    d = rb(at, n * 4)
    return [struct.unpack_from("<I", d, 4 * i)[0] for i in range(len(d) // 4)]


def wrmem(at, blob):
    out, err, rc = wmx("wr", hex(at), blob.hex())
    return rc == 0


# ---------------------------------------------------------------- symbol resolution (own process)
RESOLVER = r"""
#include <stdio.h>
#include <dlfcn.h>
static void show(const char *name, void *p) {
    Dl_info i;
    if (!p) { printf("%s 0 0 -\n", name); return; }
    if (!dladdr(p, &i)) { printf("%s %p 0 ?\n", name, p); return; }
    printf("%s %p %p %s\n", name, p, i.dli_fbase, i.dli_fname);
}
int main(void) {
    void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", 2);
    show("objc_msgSend", dlsym(RTLD_DEFAULT, "objc_msgSend"));
    show("sel_registerName", dlsym(RTLD_DEFAULT, "sel_registerName"));
    show("objc_getClass", dlsym(RTLD_DEFAULT, "objc_getClass"));
    show("class_getInstanceMethod", dlsym(RTLD_DEFAULT, "class_getInstanceMethod"));
    show("method_getImplementation", dlsym(RTLD_DEFAULT, "method_getImplementation"));
    show("objc_retain", dlsym(RTLD_DEFAULT, "objc_retain"));
    { void *sw = dlopen("/usr/lib/swift/libswiftCore.dylib", 2);
      show("swift_retain", dlsym(sw, "swift_retain"));
      show("swift_release", dlsym(sw, "swift_release")); }
    show("SLSTransactionCreate", dlsym(sl, "SLSTransactionCreate"));
    show("SLSTransactionSetWindowTransform3D", dlsym(sl, "SLSTransactionSetWindowTransform3D"));
    show("SLSTransactionSetWindowTransform", dlsym(sl, "SLSTransactionSetWindowTransform"));
    show("SLSTransactionSetWindowLevel", dlsym(sl, "SLSTransactionSetWindowLevel"));
    show("SLSTransactionCommit", dlsym(sl, "SLSTransactionCommit"));
    show("CGSMainConnectionID", dlsym(sl, "CGSMainConnectionID"));
    return 0;
}
"""


def resolve():
    src, exe = SCRATCH + "/symres.c", SCRATCH + "/symres"
    os.makedirs(SCRATCH, exist_ok=True)
    open(src, "w").write(RESOLVER)
    out, err, rc = sh("clang -O1 -o %s %s" % (exe, src))
    if rc != 0:
        raise Refuse("cannot build the symbol resolver: " + err)
    out, err, rc = sh(exe)
    d = {}
    for line in out.split("\n"):
        f = line.split()
        if len(f) == 4:
            try:
                d[f[0]] = {"addr": int(f[1], 16), "base": int(f[2], 16), "path": f[3]}
            except ValueError:
                pass
    return d


def wm_base_for(path, cache={}):
    if path in cache:
        return cache[path]
    out, err, rc = wmx("imgbase", path)
    if rc != 0:
        raise Refuse("cannot read the WM's image list: " + err)
    exact = base = None
    for line in out.split("\n"):
        f = line.split(None, 1)
        if len(f) != 2:
            continue
        try:
            a = int(f[0], 16)
        except ValueError:
            continue
        p2 = f[1].strip()
        if p2 == path:
            exact = a
            break
        if base is None and p2.endswith("/" + os.path.basename(path)):
            base = a
    got = exact if exact is not None else base
    if got is None:
        raise Refuse("the WM does not map " + path)
    cache[path] = got
    return got


def wm_addr(sy, name):
    e = sy.get(name)
    if not e or not e["addr"]:
        raise Refuse("symbol %s not resolved" % name)
    return wm_base_for(e["path"]) + (e["addr"] - e["base"])


def keeper_live(k, inst):
    """A keeper's address inside THIS WindowManager.

    The keepers live in the dyld shared cache, and on macOS 27 that cache is slid *per process*:
    a helper's dlsym slide (what `wmlocate --slide auto` reports) and a live address cached from
    a previous WM instance are both not this process's slide.  After a WindowManager restart a
    cached live address is off by the difference between the two slides, which made `doctor`
    refuse a perfectly good build and `pristine` compare the wrong bytes (round 34).  The only
    valid computation is the WM's own image base plus the file offset inside that image, which
    is slide-independent -- so this is recomputed per call and never cached."""
    fva = inst["keepers"][k][0]
    img = inst["images"]["SkyLight"]
    base = int(img.get("base", img.get("image_base")))
    return wm_base_for(img.get("path") or SKYLIGHT) + (fva - base)


# ---------------------------------------------------------------- encoders / decoders
def enc_b(pc, target):
    d = target - pc
    if d % 4 or not (-DIRECT_REACH - 4 <= d <= DIRECT_REACH):
        raise Refuse("b out of range %#x->%#x" % (pc, target))
    return 0x14000000 | ((d >> 2) & 0x03FFFFFF)


def enc_bl(pc, target):
    d = target - pc
    if d % 4 or not (-DIRECT_REACH - 4 <= d <= DIRECT_REACH):
        raise Refuse("bl out of range %#x->%#x" % (pc, target))
    return 0x94000000 | ((d >> 2) & 0x03FFFFFF)


def enc_adrp(pc, target, rd=16):
    d = (target & ~0xFFF) - (pc & ~0xFFF)
    if d % 0x1000 or not (-(1 << 32) <= d < (1 << 32)):
        raise Refuse("adrp out of range %#x->%#x" % (pc, target))
    imm = d >> 12
    return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | rd


def enc_add(xd, xn, imm):
    return 0x91000000 | ((imm & 0xFFF) << 10) | (xn << 5) | xd


def jump_seq(pc, target):
    return [enc_adrp(pc, target), enc_add(16, 16, target & 0xFFF), 0xD61F0200]


def bl_target(word, pc):
    if (word & 0xFC000000) != 0x94000000:
        return 0
    imm = word & 0x3FFFFFF
    if imm & 0x2000000:
        imm -= 0x4000000
    return pc + imm * 4


def is_bl(word):
    return (word & 0xFC000000) == 0x94000000


def le32(*w):
    return b"".join(struct.pack("<I", x & 0xFFFFFFFF) for x in w)


# ---------------------------------------------------------------- doctor
def image_text_range(macho):
    t = macho.section("__TEXT", "__text")
    return t["addr"], t["addr"] + t["size"]


# ---- issue #6: validating an *armed* install ------------------------------------------------
# A healthy armed install deliberately differs from the on-disk image at exactly six places, so
# comparing live bytes to `payload.img` (the pristine test) must fail on it.  The armed test is
# not a relaxation of that one; it is a different set of assertions, all of which can be made
# from the records the install itself wrote:
#   * each site still holds the stub bytes recorded in backup.json
#   * each recorded stub lands inside the recorded island page
#   * the running body is the payload image on disk
# The decoders below are the only non-obvious part, and they take bytes + address only, so the
# comparison logic is unit-tested without a WindowManager (wmship/tests/test_cli_modes.py).

def branch_target(word, pc):
    """Target of a direct `b`/`bl` at `pc`, or 0 when the word is neither."""
    if (word & 0x7C000000) != 0x14000000:
        return 0
    imm = word & 0x3FFFFFF
    if imm & 0x2000000:
        imm -= 0x4000000
    return pc + imm * 4


def stub_target(blob, addr):
    """The island address a recorded site stub lands on.

    The four __TEXT sites are replaced by a single direct `b` to their island stub; the two
    keepers get a three-word `adrp x16 / add x16,x16 / br x16` because a direct branch from the
    shared cache cannot reach a page near WindowManager.  Returns 0 for anything else."""
    b = bytes(blob)
    if len(b) == 4:
        return branch_target(struct.unpack_from("<I", b)[0], addr)
    if len(b) == 12:
        w0, w1, w2 = struct.unpack_from("<III", b)
        if (w0 & 0x9F00001F) != 0x90000010:          # adrp x16, #imm
            return 0
        if (w1 & 0xFFC003FF) != 0x91000210:          # add x16, x16, #imm12
            return 0
        if w2 not in (0xD61F0200, 0xD63F0200):       # br x16 / blr x16
            return 0
        imm = ((w0 >> 29) & 3) | (((w0 >> 5) & 0x7FFFF) << 2)
        if imm & (1 << 20):
            imm -= 1 << 21
        return ((addr & ~0xFFF) + (imm << 12)) + ((w1 >> 10) & 0xFFF)
    return 0


ISLAND_SIZE = 0x4000


def armed_site_checks(bak, read, island):
    """Every recorded site must still hold its stub bytes, and the stub must land in the island.

    `read(addr, n) -> bytes` is the only live dependency, so a test can pass a dictionary-backed
    reader instead of the WindowManager.  The returned rows name the site in `check` and in the
    failure detail (`<site>.stub-bytes: <site>`), which is what makes a corrupted stub an
    actionable failure rather than a bare count."""
    rows = []
    lo, hi = int(island), int(island) + ISLAND_SIZE
    recorded = (bak or {}).get("sites") or {}
    for name in SITE_NAMES:
        si = recorded.get(name)
        if not si:
            rows.append({"check": "%s.stub-recorded" % name, "ok": False,
                         "detail": "backup.json has no entry for %s — reinstall" % name})
            continue
        want = bytes.fromhex(si["new"])
        got = read(int(si["addr"]), len(want))
        if got != want:
            rows.append({"check": "%s.stub-bytes" % name, "ok": False,
                         "detail": "site %s at %#x: live %s != recorded stub %s"
                                   % (name, int(si["addr"]), got.hex() or "?", want.hex())})
            continue
        rows.append({"check": "%s.stub-bytes" % name, "ok": True,
                     "detail": "site %s at %#x: %s" % (name, int(si["addr"]), want.hex())})
        tgt = stub_target(want, int(si["addr"]))
        stub = int(si.get("stub") or 0)
        ok = bool(tgt) and tgt == stub and lo <= stub < hi
        rows.append({"check": "%s.stub-target" % name, "ok": ok,
                     "detail": "site %s stub %#x -> %#x (recorded %#x, island [%#x,%#x))"
                               % (name, int(si["addr"]), tgt, stub, lo, hi)})
    return rows


def doctor_mode(requested, state, pid):
    """Which set of assertions `doctor` must make.

    `None` is auto and follows the state file: an install whose recorded pid is the running
    WindowManager is armed.  An explicit mode the state cannot support is a refusal — silently
    downgrading `armed` to `pristine` would turn "our patch is inconsistent" into "PASS"."""
    if requested in ("pristine", "armed"):
        if requested == "armed" and not (state and state.get("pid") == pid):
            raise Refuse("doctor --mode armed: %s does not describe the running WindowManager "
                         "(installed pid %s, running pid %s); nothing of ours is installed"
                         % (STATE, (state or {}).get("pid"), pid))
        return requested
    return "armed" if state and state.get("pid") == pid else "pristine"


def image_seal(disk, live, relocs, n):
    """sha256 of two copies of an image with the relocated words masked out of both.

    The body in the process is `payload.img` with the `_SL` symbol table overwritten with this
    process's addresses, so a plain hash of the file can never equal a hash of the running body.
    Masking the same spans (the ones install() writes into the image before copying it) leaves a
    digest that is comparable across processes."""
    def masked(buf):
        b = bytearray(bytes(buf)[:n])
        for off, ln in relocs:
            if off < len(b):
                b[off:off + ln] = b"\0" * min(ln, len(b) - off)
        return bytes(b)
    return hashlib.sha256(masked(disk)).hexdigest(), hashlib.sha256(masked(live)).hexdigest()


def body_image_check(st, read):
    """The body the WindowManager is running must be the payload image on disk.

    Two independent facts: the payload on disk is unchanged since the install (`img_sha256` in
    state.json), and the live body matches it outside the relocated symbol table."""
    disk_sha = img_sha256()
    was = st.get("img_sha256")
    if was and disk_sha and was != disk_sha:
        return False, ("payload.img changed since the install (installed %s, on disk %s) — "
                       "reinstall to run the image that is on disk" % (was[:12], disk_sha[:12]))
    try:
        with open(W + "/payload.img", "rb") as f:
            disk = f.read()
    except Exception as e:
        return False, "cannot read payload.img: %s" % e
    try:
        syms = st["syms"]
        body = int(st["body"])
    except Exception:
        return False, "state.json has no body/syms — reinstall"
    live = read(body, len(disk))
    if len(live) != len(disk):
        return False, "read %d of %d body bytes at %#x" % (len(live), len(disk), body)
    relocs = st.get("relocs") or [[syms["_SL"], 8 * 32]]
    a, b = image_seal(disk, live, relocs, len(disk))
    if a == b:
        return True, "body %#x == payload.img %s (symbol table masked)" % (body, a[:16])
    return False, "body %#x is not payload.img: live %s, disk %s" % (body, b[:16], a[:16])


def doctor(wm_binary=None, live=None, as_json=False, mode=None):
    """Resolve all six sites, validate them against the code that is running, and print a report.

    Two modes with two sets of assertions (issue #6): `pristine` — nothing of ours is installed —
    and `armed` — state.json describes this WindowManager.  See `doctor_mode` for how the mode is
    chosen.  Never writes."""
    from wmlocate import FatOrThin, SharedCache            # read-only Mach-O reader
    rep = {"ok": False, "build": None, "text_sha256": None, "sites": {}, "checks": [],
           "refusals": [], "profile": None, "live": None, "foreign": None, "cache": None,
           "mode": None}

    def chk(name, ok, detail=""):
        rep["checks"].append({"check": name, "ok": bool(ok), "detail": detail})
        return ok

    # 1. static resolution (content + cross-reference), cached by build identity
    try:
        inst = file_sites(None)
    except Refuse as e:
        rep["refusals"].append(str(e))
        return _doctor_out(rep, as_json)
    rep["build"] = inst["build"]
    rep["text_sha256"] = inst["text_sha"]
    rep["cache"] = inst["cache"]
    key = "%s|%s" % (inst["build"], inst["text_sha"])
    rep["key"] = key
    for k in SITE_NAMES:
        if k not in inst["sites"]:
            rep["refusals"].append("site %s unresolved" % k)
    if rep["refusals"]:
        return _doctor_out(rep, as_json)

    target = wm_binary or WM_LIVE
    if wm_binary:
        if mode == "armed":
            rep["refusals"].append("doctor --mode armed: --wm-binary validates a copy, not this "
                                   "process")
            return _doctor_out(rep, as_json)
        try:
            alt = file_sites(wm_binary)
        except Refuse as e:
            rep["refusals"].append(str(e))
            return _doctor_out(rep, as_json)
        # equivalence: every WM site must be the installed site plus one constant delta, and the
        # delta must be derivable from a single load-address shift of the copy (not a different
        # function).  This is the round-28 moved-copy property, checked by content only.
        deltas = {k: alt["sites"][k] - inst["sites"][k] for k in
                  ("birth", "birth2", "birthE", "compute")}
        same = len(set(deltas.values())) == 1
        d0 = list(deltas.values())[0]
        chk("equivalent-copy", same,
            "constant delta %+#x" % d0 if same else "inconsistent deltas %s" % deltas)
        rep["foreign"] = {"path": wm_binary, "build": alt["build"],
                          "text_sha256": alt["text_sha"],
                          "delta": d0 if same else None, "sites": alt["sites"]}
        for k in ("birth", "birth2", "birthE", "compute"):
            rep["sites"][k] = {"file_va": alt["sites"][k], "file_va_hex": hex(alt["sites"][k]),
                               "live_va": None, "live_checked": False}
        for k in ("keeper3d", "keeper2d"):
            rep["sites"][k] = {"file_va": alt["keepers"][k][0],
                               "file_va_hex": hex(alt["keepers"][k][0]),
                               "live_va": None, "live_checked": False}
        rep["ok"] = same and not rep["refusals"]
        rep["mode"] = "pristine"
        return _doctor_out(rep, as_json)

    # 2. the live process, so every address is proven against the code that is running
    f = find()
    rep["live"] = {"pid": f["pid"], "slide": hex(f["slide"])}
    do_live = True if live is None else bool(live)
    try:
        rep["mode"] = doctor_mode(mode, _json_file(STATE), f["pid"])
    except Refuse as e:
        rep["refusals"].append(str(e))
        return _doctor_out(rep, as_json)
    if rep["mode"] == "armed":
        return _doctor_armed(rep, inst, f, chk, do_live, as_json)

    m0, _ = FatOrThin.open(target)
    cw0 = m0.words(inst["sites"]["compute"], 3)
    callee_file = bl_target(cw0[0], inst["sites"]["compute"]) if is_bl(cw0[0]) else 0
    if not callee_file:
        rep["refusals"].append("compute site +0 in the image is not a bl")
        return _doctor_out(rep, as_json)
    chk("compute.callee-decoded", True, "%#x" % callee_file)
    m, _ = FatOrThin.open(target)
    lo, hi = image_text_range(m)
    slide = f["slide"]

    # file bytes at the site == live bytes at the site (proves the mapping is this code)
    def same_bytes(file_va, n, live_va):
        try:
            fb = m.read(file_va, n)
        except Exception as e:
            return False, "cannot read file bytes: %s" % e
        lb = rb(live_va, n)
        if lb != fb:
            return False, "live %s != file %s" % (lb.hex(), fb.hex())
        return True, "file==live"

    live_st = {}
    for k in SITE_NAMES:
        fva = inst["sites"][k] if k in inst["sites"] else inst["keepers"][k][0]
        if k.startswith("keeper"):
            lva = keeper_live(k, inst)
        else:
            lva = fva + slide
        live_st[k] = lva
        rep["sites"][k] = {"file_va": fva, "file_va_hex": hex(fva), "live_va": lva,
                           "live_checked": bool(do_live)}
        if not do_live:
            continue
        if k.startswith("keeper"):
            ok, det = True, "shared-cache image (unslid %#x)" % fva
        else:
            ok, det = (lo + slide <= lva < hi + slide), "in live __TEXT [%#x,%#x)" % (lo + slide, hi + slide)
            chk("%s.in-text" % k, ok, det)
            if not ok:
                continue
            ok, det = same_bytes(fva, 12, lva)
            chk("%s.file-eq-live" % k, ok, "%#x: %s" % (lva, det))
            if not ok:
                continue
        w = words(lva, 3)
        if len(w) < 3:
            chk("%s.read" % k, False, "cannot read 12 bytes at %#x" % lva)
            continue
        if k in ("birth", "birth2"):
            chk("%s.bl-driver" % k, is_bl(w[0]) and bl_target(w[0], lva) == inst["sites"]["birthE"] + slide,
                "%08x -> %#x (driver %#x)" % (w[0], bl_target(w[0], lva),
                                              inst["sites"]["birthE"] + slide))
            chk("%s.replay-two-calls" % k, is_bl(w[1]) and is_bl(w[2]),
                "%08x %08x" % (w[1], w[2]))
        elif k == "birthE":
            chk("birthE.prologue", w[0] == PACIBSP and w[1] == MOV_X1_X30,
                "%08x %08x %08x (pacibsp; mov x1,x30; bl)" % tuple(w))
            # the compute call is inside the driver body, not necessarily the first call
            body = words(lva, 0x200)
            hit = [i for i, x in enumerate(body)
                   if is_bl(x) and bl_target(x, lva + 4 * i) == callee_file + slide]
            chk("birthE.calls-compute", bool(hit),
                "first bl->callee at +%#x" % (4 * hit[0]) if hit
                else "no bl to compute callee %#x in 0x800 bytes" % (callee_file + slide))
            chk("birthE.signed-return", MOV_X30_X1 in body[:0x20],
                "mov x30,x1 %s in the first 0x80 bytes"
                % ("present" if MOV_X30_X1 in body[:0x20] else "missing"))
        elif k == "compute":
            tgt = bl_target(w[0], lva)
            chk("compute.bl", is_bl(w[0]) and tgt == callee_file + slide,
                "%08x -> %#x (callee %#x)" % (w[0], tgt, callee_file + slide))
            chk("compute.replay-words", w[1] == 0xAA0003F3 and w[2] == 0xD10403A8,
                "%08x %08x (mov x19,x0; sub x8,x29,#0x100)" % (w[1], w[2]))
            if is_bl(w[0]):
                cw = words(tgt, 1) if tgt else []
                chk("compute.callee-prologue", bool(cw) and cw[0] == PACIBSP,
                    "%08x at callee" % (cw[0] if cw else 0))
        else:
            okp = (w[0] == PACIBSP and (w[1] & 0xFFC003FF) == 0xD10003FF
                   and ((w[1] >> 10) & 0xFFF)
                   and (w[2] & 0xFFC00000) == 0x6D000000 and ((w[2] >> 5) & 0x1F) == 31)
            chk("%s.keeper-prologue" % k, okp, "%08x %08x %08x" % tuple(w))

    # the two birth sites must share their follow-up call (parallel structure, not an address)
    if do_live and len(words(live_st["birth"], 3)) == 3 and len(words(live_st["birth2"], 3)) == 3:
        a = bl_target(words(live_st["birth"], 3)[1], live_st["birth"] + 4)
        b = bl_target(words(live_st["birth2"], 3)[1], live_st["birth2"] + 4)
        chk("births.parallel-structure", a and a == b, "follow-up call %#x vs %#x" % (a, b))

    # keepers: the live address must be the one the locator derived AND the one dlsym gives
    if do_live:
        try:
            sy = resolve()
            for k, sym in (("keeper3d", "SLSTransactionSetWindowTransform3D"),
                           ("keeper2d", "SLSTransactionSetWindowTransform")):
                got = wm_addr(sy, sym)
                chk("%s.dlsym-agrees" % k, got == live_st[k], "dlsym %#x vs locator %#x"
                    % (got, live_st[k]))
        except Refuse as e:
            chk("keepers.dlsym", False, str(e))

    # 3. the object-layout profile, verified against the live process
    prof = load_profile(key)
    if not prof:
        rep["refusals"].append(
            "no WindowID layout profile for build %s (%s). The patch sites resolve, but the "
            "payload identifies windows through the WindowID class metadata and the WindowIDTable "
            "class metadata, which are per-build data. Add a profile to %s, or run an older build "
            "the profile covers. Nothing was installed." % (inst["build"], key[:40], PROFILE))
    else:
        try:
            ok, info = verify_profile(prof, do_live)
            rep["profile"] = info
            chk("profile.live-verified", ok, json.dumps(info))
            if not ok:
                rep["refusals"].append("WindowID layout profile does not verify against the live "
                                       "process: %s" % json.dumps(info))
        except Refuse as e:
            rep["profile"] = {"error": str(e)}
            rep["refusals"].append("WindowID layout profile could not be verified: %s" % e)

    rep["ok"] = bool(not rep["refusals"]) and all(c["ok"] for c in rep["checks"]) if do_live \
        else bool(not rep["refusals"])
    return _doctor_out(rep, as_json, inst=inst)


def _doctor_armed(rep, inst, f, chk, do_live, as_json):
    """The armed half of `doctor` (issue #6): every assertion is about our own install.

    A site that has been restored under us, a stub that no longer lands in the island, and a body
    that is not the payload image on disk are each a refusal that names what is wrong.  Nothing
    here compares a patch site to the on-disk image: that comparison is the *pristine* test and it
    must keep failing on a healthy armed install."""
    st = _json_file(STATE) or {}
    bak = _json_file(BAK) or {}
    rep["armed"] = {"pid": st.get("pid"), "island": hex(int(st.get("island") or 0)),
                    "body": hex(int(st.get("body") or 0)),
                    "img_sha256": st.get("img_sha256")}
    rep["profile"] = {"key": rep["key"], "present": bool(load_profile(rep["key"]))}
    for k in SITE_NAMES:
        fva = inst["sites"][k] if k in inst["sites"] else inst["keepers"][k][0]
        si = (bak.get("sites") or {}).get(k) or {}
        rep["sites"][k] = {"file_va": fva, "file_va_hex": hex(fva),
                           "live_va": si.get("addr"), "live_checked": bool(do_live)}
    if not do_live:
        rep["refusals"].append("doctor --mode armed needs the live process (do not pass --no-live)")
        return _doctor_out(rep, as_json, inst=inst)
    island = int(st.get("island") or 0)
    if not island or not bak.get("sites"):
        rep["refusals"].append("%s or %s is missing or incomplete — reinstall" % (STATE, BAK))
        return _doctor_out(rep, as_json, inst=inst)
    chk("state.pid-is-live", st.get("pid") == f["pid"],
        "installed under pid %s, live pid %s" % (st.get("pid"), f["pid"]))
    # The recorded site addresses must be the ones this build resolves to *now*: that is what ties
    # backup.json to this process, and the keeper slide is recomputed rather than trusted.
    for k in SITE_NAMES:
        si = bak["sites"].get(k) or {}
        want = keeper_live(k, inst) if k.startswith("keeper") else inst["sites"][k] + f["slide"]
        got = int(si.get("addr") or 0)
        chk("%s.addr-agrees" % k, got == want, "backup %#x vs resolved %#x" % (got, want))
    for c in armed_site_checks(bak, rb, island):
        chk(c["check"], c["ok"], c["detail"])
    ok, det = body_image_check(st, rb)
    chk("payload.image", ok, det)
    chk("profile.present", bool(rep["profile"]["present"]),
        "layout profile for build %s" % rep["key"][:48])
    rep["ok"] = bool(not rep["refusals"]) and all(c["ok"] for c in rep["checks"])
    return _doctor_out(rep, as_json, inst=inst)


def _doctor_out(rep, as_json, inst=None):
    if as_json:
        print(json.dumps(rep, indent=1, sort_keys=True))
        return 0 if rep["ok"] else 1
    print("WindowManager  build %s  __TEXT %s  sites cache: %s"
          % (rep.get("build"), (rep.get("text_sha256") or "")[:16], rep.get("cache")))
    if rep.get("live"):
        print("live pid %(pid)d  slide %(slide)s" % rep["live"])
    if rep.get("mode") == "armed":
        a = rep.get("armed") or {}
        print("mode         armed  island %s  body %s  payload %s"
              % (a.get("island"), a.get("body"), (a.get("img_sha256") or "?")[:12]))
    if rep.get("foreign"):
        fo = rep["foreign"]
        print("image        %s  build %s  __TEXT %s" % (fo["path"], fo["build"],
                                                        (fo["text_sha256"] or "")[:16]))
    for k in SITE_NAMES:
        s = rep["sites"].get(k)
        if not s:
            print("  %-9s UNRESOLVED" % k)
            continue
        print("  %-9s file %#011x%s" % (k, s["file_va"],
                                        ("  live %#011x" % s["live_va"]) if s.get("live_va") else ""))
    bad = [c for c in rep["checks"] if not c["ok"]]
    for c in rep["checks"]:
        if not c["ok"]:
            print("  FAIL %-26s %s" % (c["check"], c["detail"]))
    print("  %d checks, %d failed" % (len(rep["checks"]), len(bad)))
    for r in rep["refusals"]:
        print("REFUSING: " + r)
    print("DOCTOR: %s" % ("PASS" if rep["ok"] else "FAIL"))
    return 0 if rep["ok"] else 1


def verify_profile(prof, do_live=True):
    """The profile is data, so it is proven, not trusted: the helper must find WindowID objects
    with the profile's isa, and the WM's own WindowIDTable must agree with them."""
    need = ("widmeta", "widtable", "ivar_reg", "ivar_comp")
    miss = [k for k in need if not prof.get(k)]
    if miss:
        raise Refuse("profile is missing %s" % ", ".join(miss))
    if not do_live:
        return True, {"live": False}
    cmd = ("%s --verify --widmeta %#x --widtable %#x --ivar-reg %#x --ivar-comp %#x"
           % (WMHB, prof["widmeta"], prof["widtable"], prof["ivar_reg"], prof["ivar_comp"]))
    out, err, rc = root_in(W, cmd, 120)
    line = [l for l in out.split("\n") if l.strip().startswith("{")]
    if not line:
        raise Refuse("helper produced no verification JSON: %s" % (err.strip() or out.strip())[:300])
    info = json.loads(line[-1])
    ok = (rc == 0 and info.get("profile_ok")
          and info.get("objects", 0) > 0
          and info.get("map_entries", 0) > 0
          and info.get("map_matched", 0) * 2 >= info.get("map_entries", 0))
    return bool(ok), info


# ---------------------------------------------------------------- build
def prepare(inst=None):
    """Resolve everything, validate live, and return the six site descriptors for install()."""
    global SY, PID, DRIVER, COMPUTE_CALLEE, SITES
    inst = inst or file_sites(None)
    f = find()
    PID = f["pid"]
    slide0 = f["slide"]
    SY = resolve()
    ok, slide, info = pick_slide(inst, slide0)
    if not ok:
        raise Refuse("no slide validates the resolved sites:\n  " + "\n  ".join(info))
    DRIVER = inst["sites"]["birthE"]
    cw = words(inst["sites"]["compute"] + slide, 1)
    if not cw or not is_bl(cw[0]):
        raise Refuse("compute site %#x is not a bl" % (inst["sites"]["compute"] + slide))
    COMPUTE_CALLEE = bl_target(cw[0], inst["sites"]["compute"] + slide) - slide
    SITES = [
        dict(name="birth",   va=inst["sites"]["birth"],   kind="bl3",      stub="_i_drv",
             near=True),
        dict(name="birth2",  va=inst["sites"]["birth2"],  kind="bl3",      stub="_i_drv2",
             near=True),
        dict(name="driverE", va=inst["sites"]["birthE"],  kind="prologue", stub="_i_drvE",
             near=True),
        dict(name="compute", va=inst["sites"]["compute"], kind="ble",      stub="_i_cmp",
             near=True),
        dict(name="keeper3d", sym="SLSTransactionSetWindowTransform3D", kind="keeper",
             stub="_i_k3d", near=False),
        dict(name="keeper2d", sym="SLSTransactionSetWindowTransform",  kind="keeper",
             stub="_i_k2d", near=False),
    ]
    prof = load_profile("%s|%s" % (inst["build"], inst["text_sha"]))
    if not prof:
        raise Refuse("no WindowID layout profile for this build (see doctor)")
    pok, pinfo = verify_profile(prof)
    if not pok:
        raise Refuse("WindowID layout profile does not verify: %s" % json.dumps(pinfo))
    return slide, inst, prof, info, pinfo


def pick_slide(inst, slide0):
    """The live slide, proven by the sites' own instructions (and by file==live bytes)."""
    def check(slide):
        ev, bad = [], []
        for s in SITE_NAMES:
            if s.startswith("keeper"):
                continue
            at = inst["sites"][s] + slide
            w = words(at, 3)
            if len(w) < 3:
                bad.append("%s: cannot read 12 bytes at %#x" % (s, at))
                continue
            if s in ("birth", "birth2"):
                if not is_bl(w[0]) or bl_target(w[0], at) != inst["sites"]["birthE"] + slide:
                    bad.append("%s %#x: +0 is %08x (target %#x), want bl driver"
                               % (s, at, w[0], bl_target(w[0], at)))
                    continue
                if not (is_bl(w[1]) and is_bl(w[2])):
                    bad.append("%s %#x: +4/+8 not two bl" % (s, at))
                    continue
            elif s == "birthE":
                if w[0] != PACIBSP or w[1] != MOV_X1_X30:
                    bad.append("%s %#x: %08x %08x, want pacibsp; mov x1,x30"
                               % (s, at, w[0], w[1]))
                    continue
            elif s == "compute":
                if not is_bl(w[0]) or (w[1], w[2]) != (0xAA0003F3, 0xD10403A8):
                    bad.append("%s %#x: %08x %08x %08x, want bl; mov x19,x0; sub x8,x29,#0x100"
                               % (s, at, *w))
                    continue
            ev.append("%-8s %#011x %s" % (s, at, " ".join("%08x" % x for x in w)))
        return (not bad), (bad or ev)

    tried, info = [], []
    for s in [slide0, 0] + [slide0 + d for d in (0x4000, -0x4000, 0x8000, -0x8000)]:
        if s in tried:
            continue
        tried.append(s)
        ok, info = check(s)
        if ok:
            return True, s, info
    return False, None, (info or ["no candidate"])


# ---------------------------------------------------------------- image
def load_image():
    img = bytearray(open(W + "/payload.img", "rb").read())
    sy = json.load(open(W + "/payload.syms.json"))
    return img, sy["syms"], {s["name"]: s for s in sy["sections"]}


# ---------------------------------------------------------------- island placement
def guard_candidates():
    out, err, rc = root("vmmap --wide %d" % PID, 90)
    rows = []
    for line in out.split("\n"):
        if "-" not in line or "[ " not in line:
            continue
        f = line.split()
        for tok in f:
            if "-" not in tok:
                continue
            try:
                a, b = [int(x, 16) for x in tok.split("-")]
            except ValueError:
                continue
            if b - a != 0x4000 or "---/" not in line or "rwx" not in line.split("---/")[1][:4]:
                continue
            kind = 3
            if "Malloc Guard Page" in line:
                kind = 0
            elif "Untagged" in line and "SM=NUL" in line:
                kind = 1
            elif "---/rwx" in line:
                kind = 2
            rows.append((kind, a, line.strip()))
            break
    rows.sort(key=lambda r: (r[0], r[1]))
    return rows


def allocate_island(site_addrs):
    cands = []
    for kind, a, line in guard_candidates():
        worst = max(abs(a - s) for s in site_addrs)
        if worst <= DIRECT_REACH:
            cands.append((kind, worst, a, line))
    if not cands:
        raise Refuse("no 16K guard/reserved page within +-%d MB of the sites"
                     % (DIRECT_REACH // 0x100000))
    cands.sort()
    for kind, worst, a, line in cands[:6]:
        out, err, rc = wmx("dealloc", hex(a), hex(0x4000))
        if rc != 0:
            log("island: dealloc %#x failed: %s" % (a, out))
            continue
        out, err, rc = wmx("allocat", hex(a), hex(0x4000))
        if rc != 0:
            log("island: allocat %#x failed: %s" % (a, out))
            continue
        log("island %#x (worst %d MB from a site; %s)" % (a, worst // 0x100000, line))
        return a, kind, line
    raise Refuse("could not take a near page")


# ---------------------------------------------------------------- control plane
def build_config_text():
    return json.dumps(dict(CFG_DEFAULT, gen=1)) + "\n"


def write_cfg(cfg):
    st = json.load(open(STATE))
    text = cfg.rstrip("\n") + "\n"
    if len(text) > 1535:
        raise Refuse("cfg too long")
    b = text.encode()
    if not wrmem(st["addr"] + st["io"]["cfg_len"], struct.pack("<I", len(b))):
        raise Refuse("cfg len write failed")
    if not wrmem(st["addr"] + st["io"]["cfg"], b):
        raise Refuse("cfg write failed")
    gen = int(time.time() * 1000) & 0x7FFFFFFF
    if not wrmem(st["addr"] + st["io"]["cfg_gen"], struct.pack("<I", gen)):
        raise Refuse("cfg gen write failed")
    return len(b)


def write_req(req):
    st = json.load(open(STATE))
    b = (json.dumps(req) + "\n").encode()
    wrmem(st["addr"] + st["io"]["rq"], b)
    wrmem(st["addr"] + st["io"]["rq_len"], struct.pack("<I", len(b)))
    gen = int(time.time() * 1000) & 0x7FFFFFFF
    wrmem(st["addr"] + st["io"]["rq_gen"], struct.pack("<I", gen))
    wrmem(st["addr"] + st["io"]["ss_len"], struct.pack("<I", 3))
    wrmem(st["addr"] + st["io"]["ss"], b"new")
    return len(b)


# ---------------------------------------------------------------- install
PENDING = D + "/pending.json"


def cleanup_orphans():
    """A failed or killed install can leave the island page and the body allocated.  The marker
    is written the moment they exist; anything the marker names and the state file does not is
    freed here before the next attempt."""
    try:
        p = json.load(open(PENDING))
    except Exception:
        return
    try:
        st = json.load(open(STATE))
        if st.get("pid") == p.get("pid") and st.get("body") == p.get("body"):
            return                                   # a live install owns them
    except Exception:
        pass
    if p.get("body"):
        wmx("dealloc", hex(p["body"]), hex(p.get("size", 0)))
    if p.get("island"):
        wmx("dealloc", hex(p["island"]), hex(0x4000))
        if wmx("allocat", hex(p["island"]), hex(0x4000))[2] == 0:
            wmx("prot", hex(p["island"]), hex(0x4000), "none")
    log("cleaned orphan allocations island=%s body=%s"
        % (p.get("island"), p.get("body")))
    try:
        os.unlink(PENDING)
    except Exception:
        pass


def img_sha256():
    """Identity of the payload body the tree would install right now."""
    try:
        with open(W + "/payload.img", "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except Exception:
        return None


def install():
    global SY, PID
    os.makedirs(D, exist_ok=True)
    cleanup_orphans()
    f = find()
    PID, slide0 = f["pid"], f["slide"]
    os.makedirs(D, exist_ok=True)
    # "already installed" must mean "already installed *from this image*".  Keying it on the pid
    # alone made a rebuilt payload.img a silent no-op: the WM kept executing the previous body
    # while the tree on disk (and `status`) described the new one, which voided a whole round of
    # resize trials (round 34, §13.1).  A different image is uninstalled and reinstalled.
    try:
        st = json.load(open(STATE))
        if st["pid"] == PID:
            same = st.get("img_sha256") == img_sha256()
            if same:
                print("already installed: pid %d island %#x body %#x (same payload image)"
                      % (PID, st["island"], st["addr"]))
                return 0
            print("payload image changed since the install — reinstalling (was %s)"
                  % (st.get("img_sha256") or "unrecorded")[:12])
            uninstall()
            PID = find()["pid"]
    except Exception:
        pass
    slide, inst, prof, info, pinfo = prepare()
    print("sites resolved (wmlocate, cache %s) and validated at slide %#x:" % (inst["cache"], slide))
    for line in info:
        print("  " + line)
    print("layout profile verified: WindowID isa %#x, WindowIDTable %#x, %d objects / %d table "
          "entries, %d matched" % (prof["widmeta"], prof["widtable"], pinfo.get("objects", 0),
                                  pinfo.get("map_entries", 0), pinfo.get("map_matched", 0)))
    site_addrs = [(wm_addr(SY, s["sym"]) if "sym" in s else s["va"] + slide, s) for s in SITES]
    img, syms, secs = load_image()
    island_sec = secs["__TEXT,__island"]
    size = (len(img) + 0x3FFF) & ~0x3FFF

    k3d = wm_addr(SY, "SLSTransactionSetWindowTransform3D")
    k2d = wm_addr(SY, "SLSTransactionSetWindowTransform")
    order = [("driver", DRIVER + slide), ("compute", COMPUTE_CALLEE + slide),
             ("objc_getClass", wm_addr(SY, "objc_getClass")),
             ("sel_registerName", wm_addr(SY, "sel_registerName")),
             ("class_getInstanceMethod", wm_addr(SY, "class_getInstanceMethod")),
             ("method_getImplementation", wm_addr(SY, "method_getImplementation")),
             ("swift_retain", wm_addr(SY, "swift_retain")),
             ("objc_retain", wm_addr(SY, "objc_retain")),
             ("txn_set3d", k3d), ("txn_set2d", k2d),
             ("txn_create", wm_addr(SY, "SLSTransactionCreate")),
             ("txn_level", wm_addr(SY, "SLSTransactionSetWindowLevel")),
             ("txn_commit", wm_addr(SY, "SLSTransactionCommit")),
             ("cgid_main", wm_addr(SY, "CGSMainConnectionID")),
             ("widmeta", prof["widmeta"] + slide), ("entry3d", k3d), ("entry2d", k2d),
             ("magic", 0x77334D4F4E4559)]
    for i, (k, v) in enumerate(order):
        struct.pack_into("<Q", img, syms["_SL"] + 8 * i, v)

    island, ikind, iline = allocate_island([a for a, s in site_addrs if s["near"]])
    out, err, rc = wmx("alloc", hex(size))
    if rc != 0:
        raise Refuse("body allocation failed: " + err)
    body = int(out.strip().split("\n")[-1], 16)
    json.dump({"pid": PID, "island": island, "body": body, "size": size, "t": time.time()},
              open(PENDING, "w"))
    print("island %#x (near, %s)   body %#x (%d bytes, far)"
          % (island, iline.split()[0], body, size))

    if not wrmem(body, bytes(img)):
        raise Refuse("body write failed")
    spl = min([sec["off"] for name, sec in secs.items() if name.startswith("__DATA")] or [0x8000])
    spl &= ~0x3FFF
    wmx("prot", hex(body), hex(spl), "rx")
    wmx("prot", hex(body + spl), hex(size - spl), "rw")

    isl = bytearray(img[island_sec["off"]:island_sec["off"] + island_sec["size"]])
    a = lambda sym: island + (syms[sym] - island_sec["off"])
    stubs = {}
    for at, s in site_addrs:
        stub = s["stub"]
        body_fn = {"birth": "_p_drv", "birth2": "_p_drv", "driverE": "_p_drv",
                   "compute": "_p_compute", "keeper3d": "_p_keeper",
                   "keeper2d": "_p_keeper"}[s["name"]]
        struct.pack_into("<Q", isl, syms[stub + "_body"] - island_sec["off"], body + syms[body_fn])
        if s["kind"] == "prologue":
            struct.pack_into("<I", isl, syms[stub + "_ret"] - island_sec["off"],
                             enc_b(a(stub + "_ret"), at + 4))
        elif s["kind"] == "keeper":
            for i in range(3):
                struct.pack_into("<I", isl, syms["%s_i%d" % (stub, i + 1)] - island_sec["off"],
                                 words(at + 4 * i, 1)[0])
            w_ra, w_rb = "%s_ra" % stub, "%s_rb" % stub
            tgt = at + 12
            struct.pack_into("<I", isl, syms[w_ra] - island_sec["off"], enc_adrp(a(w_ra), tgt))
            struct.pack_into("<I", isl, syms[w_rb] - island_sec["off"],
                             enc_add(16, 16, tgt & 0xFFF))
        else:
            n = 3 if s["kind"] == "bl3" else 1
            for i in range(n):
                w = words(at + 4 * i, 1)[0]
                t = bl_target(w, at + 4 * i)
                if not t:
                    raise Refuse("%s +%d is not a bl" % (s["name"], 4 * i))
                struct.pack_into("<I", isl, syms["%s_c%d" % (stub, i)] - island_sec["off"],
                                 enc_bl(a("%s_c%d" % (stub, i)), t))
            struct.pack_into("<I", isl, syms[stub + "_ret"] - island_sec["off"],
                             enc_b(a(stub + "_ret"), at + 12))
        stubs[s["name"]] = a(stub)
    if not wrmem(island, bytes(isl)):
        raise Refuse("island write failed")
    wmx("prot", hex(island), hex(0x4000), "rx")

    io = {k: syms["_io_" + k] for k in
          ("cfg", "cfg_len", "cfg_gen", "st", "st_len", "st_gen", "rq", "rq_len", "rq_gen",
           "ids", "ids_len", "ids_gen", "pd", "pd_len", "pd_gen", "rg", "rg_len", "rg_gen",
           "rdv", "rdv_ack", "hb", "hb_len", "poses", "poses_len", "log", "log_w",
           "res", "res_len", "ss", "ss_len",
           "self", "self_len", "inj_n", "inj_wid", "inj_cg", "mw_n", "mw", "magic",
           "widcg", "widcg_len", "widcg_gen", "wids", "wids_len", "wids_gen")}
    cfg = build_config_text().encode()
    wrmem(body + io["cfg"], cfg)
    wrmem(body + io["cfg_len"], struct.pack("<I", len(cfg)))
    wrmem(body + io["cfg_gen"], struct.pack("<I", int(time.time() * 1000) & 0x7FFFFFFF))

    bak = {"pid": PID, "slide": slide, "island": island, "kind": ikind,
           "body": body, "size": size, "io": io, "syms": syms, "sites": {},
           "relocs": [[syms["_SL"], 8 * len(order)]],
           "build": inst["build"], "text_sha256": inst["text_sha"],
           "profile_key": "%s|%s" % (inst["build"], inst["text_sha"]),
           "widmeta": prof["widmeta"], "widtable": prof["widtable"]}
    done = []
    for at, s in site_addrs:
        blob = (le32(enc_b(at, stubs[s["name"]])) if s["near"]
                else le32(*jump_seq(at, stubs[s["name"]])))
        cur = rb(at, len(blob))
        if len(cur) != len(blob):
            raise Refuse("cannot read %s" % s["name"])
        out, err, rc = wmx("remap", hex(at & ~0x3FFF), str(at & 0x3FFF), blob.hex())
        if rc != 0:
            raise Refuse("remap %s failed: %s" % (s["name"], out))
        wmx("prot", hex(at & ~0x3FFF), hex(0x4000), "rx")
        if rb(at, len(blob)) != blob:
            raise Refuse("verify %s failed" % s["name"])
        bak["sites"][s["name"]] = {"addr": at, "orig": cur.hex(), "len": len(blob),
                                   "new": blob.hex(), "stub": stubs[s["name"]]}
        done.append(s["name"])
    try:
        os.unlink(PENDING)
    except Exception:
        pass
    json.dump(bak, open(BAK, "w"), indent=1)
    st = {"pid": PID, "slide": slide, "island": island, "body": body, "addr": body,
          "size": size, "io": io, "syms": syms, "patched": done, "t": time.time(),
          "img_sha256": img_sha256(), "relocs": bak["relocs"],
          "build": inst["build"], "text_sha256": inst["text_sha"],
          "widmeta": prof["widmeta"], "widtable": prof["widtable"],
          "profile_key": bak["profile_key"]}
    json.dump(st, open(STATE, "w"), indent=1)
    with open(MAP, "w") as m:
        m.write("pid %d\nbody %#x\nisland %#x\n" % (PID, body, island))
        for k, v in io.items():
            m.write("io_%s %#x\n" % (k, body + v))
        for k in ("_SL", "_G"):
            m.write("%s %#x\n" % (k, body + syms[k]))
    log("INSTALLED pid=%d island=%#x body=%#x sites=%s" % (PID, island, body, done))
    print("patched: " + ", ".join("%s@%#x -> %#x" % (n, bak["sites"][n]["addr"],
                                                     bak["sites"][n]["stub"]) for n in done))
    return 0


# ---------------------------------------------------------------- read-back
def rd_sym(name, n):
    st = json.load(open(STATE))
    return rb(st["addr"] + st["syms"][name], n)


def hbtext():
    """The heartbeat JSON, sliced by the payload's own length field: the page is not zero-filled
    behind the text, so splitting on NUL appends the tail of the previous, longer write."""
    n = struct.unpack("<I", rd_sym("_io_hb_len", 4))[0]
    n = max(0, min(n, 1024))
    return rd_sym("_io_hb", max(1, n))[:n].decode(errors="replace")


def hb():
    print(hbtext().strip() or "(empty)")


def logdump():
    st = json.load(open(STATE))
    w = struct.unpack("<I", rd_sym("_io_log_w", 4))[0]
    ring = rd_sym("_io_log", 4096)
    n = min(w, 4096)
    if not n:
        print("(empty)")
        return
    start = (w - n) % 4096
    data = (ring[start:] + ring[:start]) if start else ring[:n]
    sys.stdout.write(data.decode(errors="replace"))


def counters():
    st = json.load(open(STATE))
    hbj = hbtext()
    d = {}
    try:
        d = json.loads(hbj)
    except Exception:
        pass
    inj_n = struct.unpack("<I", rd_sym("_io_inj_n", 4))[0]
    wid = [struct.unpack("<Q", rb(st["addr"] + st["syms"]["_io_inj_wid"] + 8 * i, 8))[0]
           for i in range(8)]
    cg = [struct.unpack("<I", rb(st["addr"] + st["syms"]["_io_inj_cg"] + 4 * i, 4))[0]
          for i in range(8)]
    print(json.dumps({"hb": d, "inj_n": inj_n,
                      "injected": [{"wid": hex(w), "cgid": c} for w, c in zip(wid, cg) if w]},
                     indent=1))


# ---------------------------------------------------------------- status
def _procs():
    def pg(pat):
        out, _, _ = sh("pgrep -fl %s" % pat)
        return [l for l in out.split("\n") if l.strip()]
    return {"lldb": pg("^lldb$") + pg("Resources/debugserver"),
            "helper": pg("wmhb"), "observers": pg("wmobs") + pg("r21obs"),
            "daemon": pg("wmshipd.py")}


def _launchd_loaded():
    out, err, rc = sh("/bin/launchctl print system/com.stagemgr.wmshipd")
    return rc == 0


def status(as_json=False):
    """Human text by default (byte-identical to every earlier round), machine-readable with
    `status --json` for the companion app.  The text path keeps its exact early returns: when the
    tool is not installed, or the live WindowManager cannot be read, there is no capability line
    to print.  The JSON path always emits the whole object, with `state: DISARMED` and a `reason`,
    so a DISARMED tool renders instead of crashing the caller."""
    pr = _procs()
    try:
        st = json.load(open(STATE))
        bak = json.load(open(BAK))
    except Exception:
        st = bak = None
    d = {"build": (bak or {}).get("build"),
         "text_sha": (bak or {}).get("text_sha256"),
         "profile_key": (bak or {}).get("profile_key"),
         "pid": None, "installed_pid": None, "slide": None,
         "state": "DISARMED", "reason": None,
         "sites_patched": 0, "sites_total": 6, "sites_bad": [],
         "caps": {}, "debugger": None if not pr["lldb"] else "; ".join(pr["lldb"]),
         "helper": [x.split(None, 1)[0] for x in pr["helper"]],
         "observers": [x.split(None, 1)[0] for x in pr["observers"]],
         "daemon": {"loaded": _launchd_loaded(),
                    "pids": [x.split(None, 1)[0] for x in pr["daemon"]]},
         "payload": None, "counters": None}
    try:
        dm = json.load(open(D + "/daemon.json"))
        d["daemon"].update({"state": dm.get("state"), "wm_pid": dm.get("wm_pid"),
                            "armed": dm.get("armed"), "reason": dm.get("reason")})
    except Exception:
        pass
    if not st:
        d["reason"] = "not installed"
        if as_json:
            print(json.dumps(d, indent=1, sort_keys=True))
            return 0
        print("build:   %s" % ((bak or {}).get("build") or "?"))
        print("text:    %s%s" % (((bak or {}).get("text_sha256") or "?")[:16],
                                 "  (profile %s)" % (bak or {}).get("profile_key", "")[:24]
                                 if bak else ""))
        print("state:   DISARMED (not installed)")
        print("debugger: %s" % ("none" if not pr["lldb"] else "; ".join(pr["lldb"])))
        return 1
    try:
        f = find()
    except Refuse as e:
        d["reason"] = str(e)
        if as_json:
            print(json.dumps(d, indent=1, sort_keys=True))
            return 0
        print("build:   %s" % ((bak or {}).get("build") or "?"))
        print("text:    %s%s" % (((bak or {}).get("text_sha256") or "?")[:16],
                                 "  (profile %s)" % (bak or {}).get("profile_key", "")[:24]
                                 if bak else ""))
        print("state:   DISARMED (%s)" % e)
        return 1
    same = f["pid"] == st["pid"]
    patched = []
    for name, si in bak["sites"].items():
        good = rb(si["addr"], si["len"]) == bytes.fromhex(si["new"]) if same else False
        patched.append((name, good))
    armed = same and all(g for _, g in patched)
    cfg = {}
    try:
        raw = rd_sym("_io_cfg", 1536).split(b"\0")[0].decode(errors="replace")
        cfg = json.loads(raw)
    except Exception:
        pass
    hbj = {}
    try:
        hbj = json.loads(hbtext())
    except Exception:
        pass

    d.update({"pid": f["pid"], "installed_pid": st["pid"], "slide": hex(f["slide"]),
              "state": "ARMED" if armed else "DISARMED",
              "sites_patched": sum(1 for _, g in patched if g),
              "sites_bad": [n for n, g in patched if not g],
              "payload": {"island": hex(st["island"]), "body": hex(st["body"]),
                          "resident": same},
              "caps": {"births": bool(cfg.get("births")),
                       "replay": bool(cfg.get("replay")),
                       "levels": bool(cfg.get("levels")),
                       "level_manual": cfg.get("level_manual", 0),
                       "s": float(cfg.get("s", 1.0)),
                       "dilate": bool(cfg.get("dilate")),
                       "move": "ready" if armed else "off"},
              "counters": {k: hbj.get(k) for k in
                           ("inject", "cmp", "ret", "miss", "rej")} if hbj else None})
    if not armed:
        d["reason"] = ("WindowManager pid changed (%s != %s)"
                       % (f["pid"], st["pid"])) if not same else \
                      "sites not patched: " + ", ".join(d["sites_bad"])
    if as_json:
        print(json.dumps(d, indent=1, sort_keys=True))
        return 0

    print("build:   %s" % ((bak or {}).get("build") or "?"))
    print("text:    %s%s" % (((bak or {}).get("text_sha256") or "?")[:16],
                             "  (profile %s)" % (bak or {}).get("profile_key", "")[:24]
                             if bak else ""))
    print("pid:     %d (installed under %d)  slide %#x" % (f["pid"], st["pid"], st["slide"]))
    print("payload: island %#x  body %#x  %s"
          % (st["island"], st["body"], "resident" if same else "gone"))
    print("state:   %s" % ("ARMED" if armed else "DISARMED"))
    print("sites:   %d/6 patched%s" % (sum(1 for _, g in patched if g),
                                       "" if armed else "  " + ", ".join(n for n, g in patched
                                                                        if not g)))
    caps = ["births=%s" % ("on" if cfg.get("births") else "off"),
            "replay=%s" % ("on" if cfg.get("replay") else "off"),
            "move=ready" if armed else "move=off",
            "strip-level=%s" % ("on" if cfg.get("levels") else "off"),
            "resize=%.2f%s" % (float(cfg.get("s", 1.0)),
                               " (dilated)" if cfg.get("dilate") else "")]
    print("caps:    " + "  ".join(caps))
    if hbj:
        print("counters: inject=%s cmp=%s ret=%s miss=%s rej=%s"
              % (hbj.get("inject"), hbj.get("cmp"), hbj.get("ret"), hbj.get("miss"),
                 hbj.get("rej")))
    print("helper:  %s" % ("none" if not pr["helper"] else ", ".join(
        x.split(None, 1)[0] for x in pr["helper"])))
    print("observers: %s" % ("none" if not pr["observers"] else ", ".join(
        x.split(None, 1)[0] for x in pr["observers"])))
    print("daemon:  %s" % ("none" if not pr["daemon"] else ", ".join(
        x.split(None, 1)[0] for x in pr["daemon"])))
    try:
        dm = json.load(open(D + "/daemon.json"))
        print("         %s pid=%s armed=%s %s" % (dm.get("state"), dm.get("wm_pid"),
                                                  dm.get("armed"), (dm.get("reason") or "")[:60]))
    except Exception:
        pass
    print("debugger: %s%s" % ("none" if not pr["lldb"] else "; ".join(pr["lldb"]),
                             "" if not pr["lldb"] else "   <- NOT ACCEPTABLE"))
    return 0 if armed and not pr["lldb"] else 1


def pristine():
    """Every site still holds the shipped image's own bytes (what uninstall must restore)."""
    from wmlocate import SharedCache, FatOrThin
    inst = file_sites(None)
    f = find()
    slide = f["slide"]
    m, _ = FatOrThin.open(WM_LIVE)
    bad = []
    for k in ("birth", "birth2", "birthE", "compute"):
        fva = inst["sites"][k]
        fb = m.read(fva, 12)
        lb = rb(fva + slide, 12)
        if fb != lb:
            bad.append("%s@%#x live %s != file %s" % (k, fva + slide, lb.hex(), fb.hex()))
            continue
        print("  %-9s %#011x %s  byte-exact with the on-disk image" % (k, fva + slide, lb.hex()))
    import wmlocate
    cdir = [d for d in wmlocate.CACHE_DIRS
            if os.path.exists(os.path.join(d, "dyld_shared_cache_arm64e"))][0]
    cacheobj = SharedCache(cdir)
    for k in ("keeper3d", "keeper2d"):
        fva = inst["keepers"][k][0]
        fb = cacheobj.read(fva, 12)
        lb = rb(keeper_live(k, inst), 12)
        if fb != lb:
            bad.append("%s live %s != cache %s" % (k, lb.hex() if lb else "?", fb.hex() if fb else "?"))
            continue
        print("  %-9s %#011x %s  byte-exact with the shared cache" % (k, keeper_live(k, inst), lb.hex()))
    print("PRISTINE: %s" % ("yes" if not bad else "NO"))
    for b in bad:
        print("  " + b)
    return 0 if not bad else 1


# ---------------------------------------------------------------- uninstall
def uninstall():
    try:
        st = json.load(open(STATE))
    except Exception:
        print("NOT INSTALLED")
        return 0
    bak = json.load(open(BAK))
    f = find()
    if f["pid"] != st["pid"]:
        print("WindowManager restarted (pid %d != %d): nothing to restore" % (f["pid"], st["pid"]))
        os.unlink(STATE)
        return 0
    bad = []
    for name, si in bak["sites"].items():
        at, orig = si["addr"], bytes.fromhex(si["orig"])
        out, err, rc = wmx("remap", hex(at & ~0x3FFF), str(at & 0x3FFF), orig.hex())
        wmx("prot", hex(at & ~0x3FFF), hex(0x4000), "rx")
        if rb(at, len(orig)) != orig:
            bad.append(name)
    wmx("dealloc", hex(st["body"]), hex(st["size"]))
    wmx("dealloc", hex(st["island"]), hex(0x4000))
    if wmx("allocat", hex(st["island"]), hex(0x4000))[2] == 0:
        wmx("prot", hex(st["island"]), hex(0x4000), "none")
    print("restored %s%s" % (", ".join(bak["sites"].keys()),
                             ("  FAILED: " + ",".join(bad)) if bad else "  (verified byte-exact)"))
    if bad:
        return 1
    os.unlink(STATE)
    return 0


if __name__ == "__main__":
    # Only the mutating commands may create D: a read-only `status` run by the console user used
    # to recreate /tmp/wmship as a user-owned empty directory after `uninstall` had removed it.
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd in ("install", "uninstall"):
        os.makedirs(D, exist_ok=True)
    args = sys.argv[2:]
    try:
        if cmd == "doctor":
            wb = None
            live = None
            js = "--json" in args
            md = None
            for i, a in enumerate(args):
                if a == "--wm-binary":
                    wb = args[i + 1]
                elif a == "--no-live":
                    live = False
                elif a == "--mode":
                    md = args[i + 1]
                    if md not in ("pristine", "armed", "auto"):
                        raise SystemExit("usage: install.py doctor [--mode pristine|armed|auto]")
                    md = None if md == "auto" else md
            sys.exit(doctor(wb, live, js, md))
        elif cmd == "pristine":
            sys.exit(pristine())
        elif cmd == "install":
            sys.exit(install())
        elif cmd == "uninstall":
            sys.exit(uninstall())
        elif cmd == "status":
            sys.exit(status("--json" in args))
        elif cmd == "find":
            print(find())
        elif cmd == "hb":
            hb()
        elif cmd == "log":
            logdump()
        elif cmd == "counters":
            counters()
        elif cmd == "cfg":
            print("cfg %d bytes" % write_cfg(" ".join(args)))
        elif cmd == "req":
            print("req %d bytes" % write_req(json.loads(" ".join(args))))
        elif cmd == "rd":
            st = json.load(open(STATE))
            print(rb(st["addr"] + st["syms"][args[0]], int(args[1], 0) if len(args) > 1 else 64).hex())
        else:
            raise SystemExit("usage: install.py doctor|pristine|install|status|uninstall|"
                             "hb|log|counters|cfg|req|rd|find")
    except Refuse as e:
        print("REFUSING: %s" % e, file=sys.stderr)
        sys.exit(3)
