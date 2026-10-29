#!/usr/bin/python3
"""wmlocate.py - locate the six Stage Manager patch sites from binary content.

    wmlocate.py [<macho-or-live>] [options]

Every site is found by signature, never by a constant address:

  compute   the unique `bl X ; mov x19,x0 ; sub x8,x29,#0x100` in __TEXT, X validated
            as a function start with a pacibsp prologue;
  birthE    (the driver) the unique bl target whose prologue is
            `pacibsp ; mov x1,x30 ; bl ; mov x30,x1`, which calls the compute callee
            from inside its own body, and which has exactly two `bl` callers;
  birth/birth2  the two `bl driver` call sites, cross-checked for parallel structure
            (the instruction after both must be a call to the same function);
  keeper3d/keeper2d  the `SLSTransactionSetWindowTransform3D` /
            `SLSTransactionSetWindowTransform` implementations in the SkyLight image
            of the dyld shared cache, resolved through the image's export trie and
            validated against the keeper prologue class.

Each candidate must satisfy structural invariants (inside __TEXT, function start,
instruction class, caller/callee relationship, argument registers).  Candidates are
scored; if a site is missing or ambiguous the tool prints a reason and exits non-zero
instead of guessing.  Results are cached in sites.json keyed by build + sha256(__text)
so a known build is instant, and every cache hit is re-verified before it is used.

Offline: this tool only reads files (the Mach-O, the dyld shared cache on disk).  It
never opens a process task port, never attaches, never writes to a code page.

Usage:
    wmlocate.py [<macho-or-live>] [options]

    <macho-or-live>     a WindowManager Mach-O (thin or universal), a .app bundle, or
                        "live" (default) for the installed
                        /System/Library/CoreServices/WindowManager.app binary.

    --slide none|auto|0xN   map the unslid SkyLight cache VAs to live ones.  "auto"
                        reads this boot's cache slide from a throwaway dyld
                        (`_dyld_get_shared_cache_range`); no target is touched.
    --wm-slide 0xN      add WindowManager's slide to the four WM sites (live_va).
    --sites PATH        cache file (default: sites.json beside this script).
    --no-cache          ignore sites.json and rescan.
    --cache-dir DIR     dyld shared cache directory.
    --skylight-image P  image to resolve the keepers in (default SkyLight).
    --quiet             no progress on stderr.

stdout is always one JSON object:

    {"ok": bool,
     "cache": "hit-verified" | "miss",
     "slide": <int|null>,
     "images": {...build, text_sha256, cache...},
     "sites": {"birth": {"file_va", "live_va", "evidence": [...], "confidence"},
               ... "keeper3d", "keeper2d"},
     "refusals": [{"site", "why"}],
     "missing": [...]}

Exit status: 0 all six sites located, 1 at least one site unresolved, 2 no such binary.
"""
import bisect
import glob
import hashlib
import json
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SITES = os.path.join(HERE, "sites.json")
CACHE_DIRS = [
    "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld",
    "/System/Library/dyld",
]
WM_LIVE = "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
SKYLIGHT = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"

CPU_ARM64E = 0x0100000C
TEXT = ("__TEXT", "__text")

PACIBSP = 0xD503237F
MOV_X1_X30 = 0xAA1E03E1
MOV_X30_X1 = 0xAA0103FE
MOV_X19_X0 = 0xAA0003F3
SUB_X8_X29_0x100 = 0xD10403A8
RET = 0xD65F03C0


def log(*a):
    print(*a, file=sys.stderr)


# ---------------------------------------------------------------- arm64 decoding
def bl_target(w, pc):
    """BL: opcode 0b100101, imm26 signed, *4, pc-relative."""
    if (w >> 26) != 0x25:
        return None
    imm = w & 0x3FFFFFF
    if imm & 0x2000000:
        imm -= 0x4000000
    return pc + imm * 4


def branch_target(w, pc):
    """B / B.cond / CBZ / CBNZ / TBZ / TBNZ -> target (used only for loop evidence)."""
    if (w >> 26) == 0x05:
        imm = w & 0x3FFFFFF
        if imm & 0x2000000:
            imm -= 0x4000000
        return pc + imm * 4
    if (w & 0xFF000010) == 0x54000000 or (w & 0x7E000000) in (0x34000000, 0x36000000):
        imm = (w >> 5) & 0x7FFFF
        if imm & 0x40000:
            imm -= 0x80000
        return pc + imm * 4
    return None


def sub_sp_imm(w):
    """SUB (immediate, 64-bit) writing SP -> imm, else None."""
    if (w & 0xFFC003FF) != 0xD10003FF:
        return None
    imm = (w >> 10) & 0xFFF
    if w & (1 << 22):
        imm <<= 12
    return imm


def stp_simd_sp(w):
    """STP dN,dM,[sp,#imm] -> (rt, rt2, imm) or None.

    Load/store pair encodes Rn in bits 5-9 and Rt2 in bits 10-14 (not the scalar order).
    """
    if (w & 0xFFC00000) != 0x6D000000:
        return None
    if ((w >> 5) & 0x1F) != 31:           # Rn must be SP
        return None
    rt = w & 0x1F
    rt2 = (w >> 10) & 0x1F
    imm = (w >> 15) & 0x7F
    if imm & 0x40:
        imm -= 0x80
    return (rt, rt2, imm * 8)


def adrp_target(w, pc):
    if (w & 0x9F000000) != 0x90000000:
        return None
    immlo = (w >> 29) & 0x3
    immhi = (w >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~0xFFF) + (imm << 12)


def uleb(b, i):
    r = 0
    sh = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << sh
        sh += 7
        if not c & 0x80:
            return r, i


# ---------------------------------------------------------------- Mach-O
class Refuse(Exception):
    def __init__(self, site, why):
        Exception.__init__(self, "%s: %s" % (site, why))
        self.site = site
        self.why = why


class MachO(object):
    """A Mach-O (one arm64e slice) read from a file, or a dylib inside the shared cache.

    The only difference between the two is how a VA is turned into bytes, so both share
    this class through the `reader` callable.
    """

    def __init__(self, path, data, offset, arch, reader=None, note=""):
        self.path = path
        self.data = data
        self.offset = offset
        self.arch = arch
        self.note = note
        self.reader = reader
        magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from(
            "<IiiIIIII", data, offset)
        if magic != 0xFEEDFACF:
            raise ValueError("%s: not a 64-bit Mach-O at %#x" % (path, offset))
        self.magic = magic
        self.cputype = cputype
        self.ncmds = ncmds
        self.flags = flags
        self.segments = []
        self.sections = {}
        self.lc = {}
        off = offset + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, off)
            if size < 8:
                raise ValueError("%s: bad load command size %d" % (path, size))
            body = data[off:off + size]
            if cmd == 0x19:                                   # LC_SEGMENT_64
                name = body[8:24].rstrip(b"\0").decode("utf-8", "replace")
                va, vs, fo, fs = struct.unpack_from("<QQQQ", body, 24)
                nsects = struct.unpack_from("<I", body, 64)[0]
                self.segments.append(dict(name=name, vmaddr=va, vmsize=vs,
                                          fileoff=fo, filesize=fs, order=len(self.segments)))
                for j in range(nsects):
                    so = 72 + 80 * j
                    if so + 48 > len(body):
                        break
                    sname = body[so:so + 16].rstrip(b"\0").decode("utf-8", "replace")
                    addr, ssize = struct.unpack_from("<QQ", body, so + 32)
                    soff = struct.unpack_from("<I", body, so + 48)[0]
                    self.sections[(name, sname)] = dict(addr=addr, size=ssize,
                                                        offset=soff, seg=name)
            elif cmd in (0x26, 0x80000033, 0x80000034, 0x1D):
                key = {0x26: "function_starts", 0x80000033: "exports_trie",
                       0x80000034: "chained_fixups", 0x1D: "code_signature"}[cmd]
                if len(body) >= 16:
                    do, ds = struct.unpack_from("<II", body, 8)
                    self.lc[key] = (do, ds)
            elif cmd == 0x2 and len(body) >= 24:              # LC_SYMTAB
                self.lc["symtab"] = struct.unpack_from("<IIII", body, 8)
            elif cmd in (0xC, 0xD) and len(body) > 24:        # LC_(LOAD|ID)_DYLIB
                so = struct.unpack_from("<I", body, 8)[0]
                nm = body[so:].split(b"\0")[0].decode("utf-8", "replace")
                if cmd == 0xD:
                    self.lc["install_name"] = nm
                self.lc.setdefault("dylibs", []).append(nm)
            elif cmd == 0x1B and len(body) >= 24:             # LC_UUID
                self.uuid = body[8:24].hex()
            off += size
        self.base = min((s["vmaddr"] for s in self.segments if s["name"] != "__PAGEZERO"),
                        default=0)
        self._fstarts = None
        self._exports = None

    # ---- VA access
    def read(self, va, n):
        if self.reader is not None:
            return self.reader.read(va, n)
        for s in self.segments:
            if s["name"] == "__PAGEZERO":
                continue
            if s["vmaddr"] <= va and va + n <= s["vmaddr"] + s["filesize"]:
                fo = self.offset + s["fileoff"] + (va - s["vmaddr"])
                return self.data[fo:fo + n]
        raise ValueError("%s: VA %#x is not file-backed" % (self.path, va))

    def u32(self, va):
        b = self.read(va, 4)
        if len(b) < 4:
            return None
        return struct.unpack("<I", b)[0]

    def words(self, va, n):
        b = self.read(va, 4 * n)
        return list(struct.unpack("<%dI" % (len(b) // 4), b[:len(b) // 4 * 4]))

    def section(self, seg, sect):
        s = self.sections.get((seg, sect))
        if not s:
            raise Refuse("image", "%s has no %s,%s" % (self.path, seg, sect))
        return s

    def blob(self, dataoff, size):
        """Bytes of a __LINKEDIT blob named by a load command's file offset.

        Yields (label, bytes) candidates: in the shared cache a dataoff is a file offset
        in whichever subcache holds __LINKEDIT, and in a plain file it is a file offset.
        The caller validates the content, so trying candidates is safe.
        """
        if self.reader is None:
            fo = self.offset + dataoff                 # dataoff is slice-relative
            if fo + size <= len(self.data):
                yield ("file-offset", self.data[fo:fo + size])
            return
        for label, b in self.reader.blob(dataoff, size):
            yield (label, b)

    # ---- function starts
    @property
    def function_starts(self):
        if self._fstarts is None:
            self._fstarts = []
            lc = self.lc.get("function_starts")
            if lc:
                for label, raw in self.blob(lc[0], lc[1]):
                    starts = []
                    addr = self.base
                    i = 0
                    try:
                        while i < len(raw):
                            v, i = uleb(raw, i)
                            if v == 0:
                                break
                            addr += v
                            starts.append(addr)
                    except IndexError:
                        starts = []
                    if len(starts) > 64:
                        self._fstarts = starts
                        log("  function starts: %d (via %s)" % (len(starts), label))
                        break
            if not self._fstarts:
                log("  %s: no usable LC_FUNCTION_STARTS; "
                    "structural checks fall back to segment bounds" % self.path)
        return self._fstarts

    def enclosing(self, va):
        st = self.function_starts
        if not st:
            t = self.section(*TEXT)
            return t["addr"], t["addr"] + t["size"], False
        k = bisect.bisect_right(st, va) - 1
        if k < 0:
            t = self.section(*TEXT)
            return t["addr"], t["addr"] + t["size"], False
        end = st[k + 1] if k + 1 < len(st) else self.section(*TEXT)["addr"] + \
            self.section(*TEXT)["size"]
        return st[k], end, va == st[k]

    def is_start(self, va):
        st = self.function_starts
        if not st:
            return None
        i = bisect.bisect_left(st, va)
        return i < len(st) and st[i] == va

    # ---- export trie
    @property
    def exports(self):
        if self._exports is None:
            self._exports = {}
            lc = self.lc.get("exports_trie")
            if lc:
                for label, raw in self.blob(lc[0], lc[1]):
                    out = {}
                    try:
                        self._walk_trie(raw, 0, "", out, set())
                    except Exception:
                        out = {}
                    if len(out) > 32:
                        self._exports = out
                        log("  export trie: %d symbols (via %s)" % (len(out), label))
                        break
            if not self._exports:
                log("  %s: no usable export trie" % self.path)
        return self._exports

    def _walk_trie(self, b, off, prefix, out, seen):
        if off in seen or off >= len(b) or len(out) > 200000:
            return
        seen.add(off)
        i = off
        tsize, i = uleb(b, i)
        if tsize:
            term_end = i + tsize
            flags, j = uleb(b, i)
            addr = None
            if not flags & 0x08:                       # not a re-export
                addr, j = uleb(b, j)
                if flags & 0x04:                       # stub + resolver
                    _, j = uleb(b, j)
            out[prefix] = dict(flags=flags, offset=addr)
            i = term_end
        if i >= len(b):
            return
        nchild = b[i]
        i += 1
        for _ in range(nchild):
            j = b.find(b"\0", i)
            if j < 0:
                return
            name = b[i:j].decode("utf-8", "replace")
            i = j + 1
            child, i = uleb(b, i)
            self._walk_trie(b, child, prefix + name, out, seen)

    def export(self, name):
        return self.exports.get(name)


class FatOrThin(object):
    """Open a Mach-O file, choosing the arm64e slice of a fat binary."""

    @staticmethod
    def open(path, arch=None):
        data = open(path, "rb").read()
        magic = struct.unpack_from(">I", data, 0)[0]
        if magic in (0xCAFEBABE, 0xCAFEBABF):
            nfat = struct.unpack_from(">I", data, 4)[0]
            best = None
            for i in range(nfat):
                cputype, cpusub, off, size, align = struct.unpack_from(">iiIII", data, 8 + 20 * i)
                if arch and cputype != arch:
                    continue
                if cputype == CPU_ARM64E and best is None:
                    best = (off, cputype, cpusub)
            if best is None:
                raise ValueError("%s: no arm64e slice" % path)
            return MachO(path, data, best[0], "arm64e"), best[0]
        if struct.unpack_from("<I", data, 0)[0] == 0xFEEDFACF:
            cputype = struct.unpack_from("<i", data, 4)[0]
            return MachO(path, data, 0, "arm64e" if cputype == CPU_ARM64E else "arm64"), 0
        raise ValueError("%s: not a Mach-O" % path)


# ---------------------------------------------------------------- shared cache
class SharedCache(object):
    """Read-only view of the dyld shared cache on disk.

    Only the per-subcache mapping table is used (address, size, file offset), which is
    the one part of the format every split cache still carries; images are found by
    their LC_ID_DYLIB, never by address.
    """

    def __init__(self, directory):
        self.dir = directory
        self.files = []
        self.mappings = []
        main = os.path.join(directory, "dyld_shared_cache_arm64e")
        if not os.path.exists(main):
            raise Refuse("skylight", "no shared cache at %s" % directory)
        head = open(main, "rb").read(0x400)
        if head[:16] != b"dyld_v1  arm64e\0":
            raise Refuse("skylight", "%s is not an arm64e dyld shared cache" % main)
        self.uuid = head[0x58:0x68].hex()
        for f in sorted(glob.glob(os.path.join(directory, "dyld_shared_cache_arm64e*"))):
            if f.endswith((".map", ".atlas")) or not os.path.isfile(f):
                continue
            self.files.append(f)
            try:
                h = open(f, "rb").read(0x400)
                mo, mc = struct.unpack_from("<II", h, 0x10)
                for i in range(mc):
                    a, s, fo, maxp, initp = struct.unpack_from("<QQQII", h, mo + 32 * i)
                    if s:
                        self.mappings.append(dict(addr=a, size=s, fileoff=fo,
                                                  path=f, prot=maxp))
            except Exception:
                continue
        self.mappings.sort(key=lambda m: m["addr"])
        self._images = {}

    def mapping(self, va):
        i = bisect.bisect_right([m["addr"] for m in self.mappings], va) - 1
        if i < 0:
            return None
        m = self.mappings[i]
        if va < m["addr"] + m["size"]:
            return m
        return None

    def read(self, va, n):
        m = self.mapping(va)
        if m is None or va + n > m["addr"] + m["size"]:
            return b""
        with open(m["path"], "rb") as fh:
            fh.seek(m["fileoff"] + (va - m["addr"]))
            return fh.read(n)

    def blob(self, dataoff, size):
        """Linkedit blobs: try dataoff as a raw subcache file offset, then as a
        mapping-relative VA.  The caller validates whichever parses."""
        for f in self.files:
            try:
                if os.path.getsize(f) < dataoff + size:
                    continue
            except OSError:
                continue
            with open(f, "rb") as fh:
                fh.seek(dataoff)
                yield ("%s+%#x" % (os.path.basename(f), dataoff), fh.read(size))
        for m in self.mappings:
            rel = dataoff - m["fileoff"]
            if 0 <= rel and rel + size <= m["size"]:
                yield ("%s->va %#x" % (os.path.basename(m["path"]), m["addr"] + rel),
                       self.read(m["addr"] + rel, size))

    def images(self):
        """Every image header found in the executable mappings, keyed by install name.


        Image headers are page aligned and start with a Mach-O magic, so the scan reads
        each executable mapping in chunks and only parses the pages that begin with one.
        """
        if self._images:
            return self._images
        out = {}
        for m in self.mappings:
            if m["size"] < 0x1000 or not (m.get("prot") or 5) & 1:
                continue
            n = os.path.getsize(m["path"])
            avail = min(m["size"], max(0, n - m["fileoff"]))
            CH = 4 << 20
            with open(m["path"], "rb") as fh:
                fh.seek(m["fileoff"])
                done = 0
                while done < avail:
                    chunk = fh.read(min(CH, avail - done))
                    if not chunk:
                        break
                    if len(chunk) > 32:
                        starts = [i for i in range(0, len(chunk) - 32, 0x1000)
                                  if chunk[i:i + 4] == b"\xcf\xfa\xed\xfe"]
                        for i in starts:
                            try:
                                img = MachO(m["path"], chunk, i, "arm64e", reader=self,
                                            note="cache %s" % os.path.basename(m["path"]))
                            except Exception:
                                continue
                            name = img.lc.get("install_name") or \
                                (img.lc.get("dylibs") or [None])[0]
                            if name:
                                img.cache_va = m["addr"] + done + i
                                out.setdefault(name, img)
                    done += len(chunk)
                    # image headers are 4K or 16K aligned; 4K covers both
        self._images = out
        return out

    def image(self, install_name):
        imgs = self.images()
        if install_name not in imgs:
            close = [k for k in imgs if install_name.split("/")[-1] in k]
            raise Refuse("skylight", "%s is not in the shared cache (%d images scanned%s)"
                         % (install_name, len(imgs),
                            "; similar: %s" % ", ".join(sorted(close)[:3]) if close else ""))
        return imgs[install_name]


# ---------------------------------------------------------------- WindowManager
def wm_prologue(m, va):
    w = m.words(va, 4)
    if len(w) < 4:
        return None
    if w[0] != PACIBSP or w[1] != MOV_X1_X30 or w[3] != MOV_X30_X1:
        return None
    if bl_target(w[2], va + 8) is None:
        return None
    return w


def find_wm_sites(m):
    """Return (sites, evidence) for the four WindowManager sites.

    Raises Refuse with a reason when a site is missing or ambiguous.
    """
    text = m.section(*TEXT)
    lo, hi = text["addr"], text["addr"] + text["size"]
    n = (hi - lo) // 4
    raw = m.read(lo, n * 4)
    words = struct.unpack("<%dI" % n, raw)

    def word_at(i):
        return words[i]

    # ---- 1. compute call site: bl X ; mov x19,x0 ; sub x8,x29,#0x100
    comp_sites = []
    for i in range(n - 2):
        if words[i + 1] != MOV_X19_X0 or words[i + 2] != SUB_X8_X29_0x100:
            continue
        pc = lo + 4 * i
        t = bl_target(words[i], pc)
        if t is None:
            continue
        comp_sites.append((pc, t))
    if len(comp_sites) != 1:
        raise Refuse("compute", "%d candidates for `bl X ; mov x19,x0 ; sub x8,x29,#0x100` "
                     "(need exactly 1)%s"
                     % (len(comp_sites), "" if not comp_sites else
                        ": " + ", ".join("%#x->%#x" % c for c in comp_sites[:6])))
    compute_site, compute = comp_sites[0]
    ev_c = ["unique `bl ; mov x19,x0 ; sub x8,x29,#0x100` at %#x" % compute_site]
    cw = m.words(compute, 3)
    if not (lo <= compute < hi):
        raise Refuse("compute", "callee %#x is outside __TEXT" % compute)
    if cw and cw[0] != PACIBSP:
        raise Refuse("compute", "callee %#x does not start with pacibsp (%08x)" % (compute, cw[0]))
    ev_c.append("callee %#x starts with pacibsp" % compute)
    if m.is_start(compute):
        ev_c.append("callee is an LC_FUNCTION_STARTS entry")
    if cw and sub_sp_imm(cw[1]) is not None:
        ev_c.append("callee prologue `pacibsp ; sub sp,#%#x`" % sub_sp_imm(cw[1]))

    # ---- 2. driver: unique bl target with the signed-return prologue that calls compute
    cands = {}
    for i in range(n):
        pc = lo + 4 * i
        t = bl_target(words[i], pc)
        if t is not None and lo <= t < hi:
            cands.setdefault(t, 0)
            cands[t] += 1
    drivers = []
    why_not = []
    close = []
    for t in sorted(cands):
        w = wm_prologue(m, t)
        if not w:
            continue
        fs, fe, is_start = m.enclosing(t)
        if m.function_starts and not is_start:
            continue
        body = m.words(t, min((fe - t) // 4, 0x2000))
        calls_compute = any(bl_target(wb, t + 4 * k) == compute
                            for k, wb in enumerate(body))
        if not calls_compute:
            why_not.append("%#x: signed-return prologue but never calls compute %#x"
                           % (t, compute))
            continue
        callers = [lo + 4 * i for i in range(n) if bl_target(words[i], lo + 4 * i) == t]
        if len(callers) != 2:
            close.append("%#x: signed prologue and calls compute, but %d `bl` callers "
                         "(need exactly 2)" % (t, len(callers)))
            continue
        drivers.append((t, callers))
    if len(drivers) != 1:
        near = close or why_not
        raise Refuse("birthE", "%d candidate driver entries (need exactly 1)%s"
                     % (len(drivers),
                        ("; closest rejected: " + "; ".join(near[:3])) if near else ""))
    driver, callers = drivers[0]
    ev_d = ["`bl` target %#x: prologue `pacibsp ; mov x1,x30 ; bl ; mov x30,x1`" % driver,
            "body calls compute %#x" % compute,
            "exactly 2 `bl` callers in __TEXT"]
    dw = m.words(driver, 4)
    t0 = bl_target(dw[2], driver + 8)
    if t0 is not None:
        ev_d.append("prologue call %#x (signed-return helper)" % t0)

    # ---- 3. the two birth sites
    sites = sorted(callers)
    if len(sites) != 2:
        raise Refuse("birth", "%d call sites to the driver" % len(sites))
    follow = []
    for s in sites:
        fw = m.words(s, 3)
        if len(fw) < 3:
            raise Refuse("birth", "cannot read 12 bytes at %#x" % s)
        if bl_target(fw[1], s + 4) is None or bl_target(fw[2], s + 8) is None:
            raise Refuse("birth", "%#x +4/+8 are not calls (%08x %08x); the installer "
                         "replays three call words" % (s, fw[1], fw[2]))
        fs, fe, _ = m.enclosing(s)
        span = loop_span(m, fs, fe, s)
        follow.append((s, bl_target(fw[1], s + 4), fs, fe, span))
    if follow[0][1] != follow[1][1]:
        raise Refuse("birth", "the two call sites are not parallel: after the driver one "
                     "calls %#x, the other %#x" % (follow[0][1], follow[1][1]))
    # the installer patches both identically; name them by VA order (birth = higher VA)
    hi_site, lo_site = follow[1], follow[0]
    sites_by_name = {"birth": hi_site, "birth2": lo_site,
                     "birthE": (driver, None, None, None, None),
                     "compute": (compute_site, None, None, None, None)}
    ev = {
        "compute": ev_c,
        "birthE": ev_d,
        "birth": ["`bl driver` at %#x (VA order: higher of the two)" % hi_site[0],
                  "the call after it is `bl %#x`, identical at both birth sites" % hi_site[1],
                  "site lies in function %#x (%d bytes)%s"
                  % (hi_site[2], hi_site[3] - hi_site[2],
                     ", innermost loop span %#x bytes" % hi_site[4] if hi_site[4] else ""),
                  "driver has exactly 2 callers, both patched"],
        "birth2": ["`bl driver` at %#x (VA order: lower of the two)" % lo_site[0],
                   "the call after it is `bl %#x`, identical at both birth sites" % lo_site[1],
                   "site lies in function %#x (%d bytes)%s"
                   % (lo_site[2], lo_site[3] - lo_site[2],
                      ", innermost loop span %#x bytes" % lo_site[4] if lo_site[4] else "")],
    }
    out = {"birth": hi_site[0], "birth2": lo_site[0], "birthE": driver,
           "compute": compute_site}
    return out, ev, {"compute_callee": compute, "driver": driver}


def loop_span(m, fs, fe, site):
    """Size of the innermost backward-branch span containing `site` (loop evidence)."""
    span = None
    for va in range(fs, fe, 4):
        t = branch_target(m.u32(va), va)
        if t is None or t >= va:
            continue
        if t <= site < va and (span is None or va - t < span):
            span = va - t
    return span


# ---------------------------------------------------------------- SkyLight
# The one canonical name table for the six patch sites.  Everything that keys sites by name --
# this tool's output, install.py's patch bookkeeping, backup.json and the armed doctor -- uses
# these names.  install.py imports this tuple instead of keeping a copy (issue #42).
SITE_NAMES = ("birth", "birth2", "birthE", "compute", "keeper3d", "keeper2d")

KEEPER_NAMES = [("keeper3d", "_SLSTransactionSetWindowTransform3D", 0x70),
                ("keeper2d", "_SLSTransactionSetWindowTransform", 0x80)]


def keeper_shape(m, va):
    """Class check for a keeper: pacibsp ; sub sp,#imm ; stp d9,d8,[sp,#0x30]."""
    return keeper_shape_words(m.words(va, 3))


def keeper_shape_words(w):
    if len(w) < 3:
        return None
    if w[0] != PACIBSP:
        return None
    imm = sub_sp_imm(w[1])
    if imm is None or imm == 0:
        return None
    stp = stp_simd_sp(w[2])
    if stp is None:
        return None
    rt, rt2, soff = stp
    if (rt, rt2) != (9, 8):                # stp d9, d8
        return None
    return dict(sub_imm=imm, stp_off=soff)


def find_skylight_sites(cache, install_name=SKYLIGHT):
    img = cache.image(install_name)
    text = img.section(*TEXT)
    lo, hi = text["addr"], text["addr"] + text["size"]
    out = {}
    ev = {}
    for name, sym, want_imm in KEEPER_NAMES:
        e = img.export(sym)
        checks = []
        va = None
        conf = 1.0
        if e and e.get("offset") is not None and not (e["flags"] & 0x08):
            va = img.base + e["offset"]
            checks.append("export trie: %s at image+%#x -> %#x" % (sym, e["offset"], va))
        if va is None:
            # fallback: the keeper prologue class, unique in __text
            hits = []
            for a in range(lo, hi - 8, 4):
                sh = keeper_shape(img, a)
                if sh and sh["sub_imm"] == want_imm:
                    hits.append(a)
            if len(hits) != 1:
                raise Refuse(name, "symbol %s missing from the export trie and %d prologue "
                             "candidates (`pacibsp ; sub sp,#%#x ; stp d9,d8`) in __text "
                             "[%#x,%#x)" % (sym, len(hits), want_imm, lo, hi))
            va = hits[0]
            conf = 0.7
            checks.append("symbol absent; prologue search found a unique candidate")
        if not (lo <= va < hi):
            raise Refuse(name, "%#x is outside SkyLight __text [%#x,%#x)" % (va, lo, hi))
        sh = keeper_shape(img, va)
        if not sh:
            raise Refuse(name, "%#x does not match the keeper prologue class "
                         "(`pacibsp ; sub sp ; stp d9,d8,[sp,#0x30]`): %s"
                         % (va, " ".join("%08x" % w for w in img.words(va, 3))))
        checks.append("prologue `pacibsp ; sub sp,#%#x ; stp d9,d8,[sp,#%#x]`"
                      % (sh["sub_imm"], sh["stp_off"]))
        if sh["sub_imm"] != want_imm:
            checks.append("note: sub sp is #%#x, reference build had #%#x"
                          % (sh["sub_imm"], want_imm))
            conf = min(conf, 0.9)
        is_start = img.is_start(va)
        if is_start:
            checks.append("entry is an LC_FUNCTION_STARTS entry")
        out[name] = va
        ev[name] = checks
        ev[name + "_shape"] = sh
    if out["keeper3d"] == out["keeper2d"]:
        raise Refuse("keeper", "the two transform sites resolved to the same address")
    # sibling check: both keepers must share the prologue class (same save slots)
    a, b = ev["keeper3d_shape"], ev["keeper2d_shape"]
    if (a["stp_off"], a["sub_imm"] % 0x10) != (b["stp_off"], b["sub_imm"] % 0x10):
        raise Refuse("keeper", "the two transform prologues do not look like siblings")
    ev["keeper3d"].append("sibling prologue class shared with keeper2d")
    ev["keeper2d"].append("sibling prologue class shared with keeper3d")
    return out, {k: v for k, v in ev.items() if not k.endswith("_shape")}


# ---------------------------------------------------------------- build keys
def bundle_version(path):
    d = os.path.dirname(os.path.abspath(path))
    for _ in range(4):
        plist = os.path.join(d, "Info.plist")
        if os.path.exists(plist):
            try:
                out = subprocess.run(["/usr/libexec/PlistBuddy", "-c",
                                      "Print :CFBundleVersion", plist],
                                     capture_output=True, text=True, timeout=10)
                if out.returncode == 0 and out.stdout.strip():
                    return out.stdout.strip()
            except Exception:
                pass
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def text_sha256(m):
    t = m.section(*TEXT)
    return hashlib.sha256(m.read(t["addr"], t["size"])).hexdigest()


# ---------------------------------------------------------------- verification of cached sites
def verify_wm(m, sites):
    """Re-check a located (or cached) site table against the bytes. Returns (ok, why)."""
    text = m.section(*TEXT)
    lo, hi = text["addr"], text["addr"] + text["size"]
    for k in ("birth", "birth2", "birthE", "compute"):
        if k not in sites:
            return False, "%s missing from the site table" % k
        if not (lo <= sites[k] < hi):
            return False, "%s %#x outside __TEXT" % (k, sites[k])
    if not wm_prologue(m, sites["birthE"]):
        return False, "birthE %#x lost its signed-return prologue" % sites["birthE"]
    for k in ("birth", "birth2"):
        w = m.u32(sites[k])
        if bl_target(w, sites[k]) != sites["birthE"]:
            return False, "%s %#x no longer calls the driver %#x" % (k, sites[k], sites["birthE"])
    cw = m.words(sites["compute"], 3)
    if len(cw) < 3 or cw[1] != MOV_X19_X0 or cw[2] != SUB_X8_X29_0x100:
        return False, "compute %#x lost its `mov x19,x0 ; sub x8,x29,#0x100` tail" % sites["compute"]
    tgt = bl_target(cw[0], sites["compute"])
    if tgt is None:
        return False, "compute %#x is no longer a call" % sites["compute"]
    w = m.words(tgt, 1)
    if not w or w[0] != PACIBSP:
        return False, "compute target %#x does not start with pacibsp" % tgt
    fs, fe, _ = m.enclosing(sites["birthE"])
    body = m.words(sites["birthE"], max(0, (fe - sites["birthE"]) // 4))
    if not any(bl_target(wb, sites["birthE"] + 4 * i) == tgt for i, wb in enumerate(body)):
        return False, "driver %#x no longer calls compute %#x" % (sites["birthE"], tgt)
    return True, "ok"


def verify_sl(m, sites):
    text = m.section(*TEXT)
    lo, hi = text["addr"], text["addr"] + text["size"]
    for k in ("keeper3d", "keeper2d"):
        va = sites.get(k)
        if va is None or not (lo <= va < hi):
            return False, "%s %s outside SkyLight __text" % (k, va)
        if not keeper_shape(m, va):
            return False, "%s %#x lost the keeper prologue" % (k, va)
    return True, "ok"


# ---------------------------------------------------------------- sites.json
def load_cache(path):
    try:
        with open(path) as f:
            d = json.load(f)
        if d.get("version") == 2:
            return d
    except Exception:
        pass
    return {"version": 2, "images": {}}


def cache_get(cache, image, key):
    return cache.get("images", {}).get(image, {}).get("builds", {}).get(key)


def cache_get_by(cache, image, field, value):
    for k, v in cache.get("images", {}).get(image, {}).get("builds", {}).items():
        if v.get(field) == value:
            return v
    return None


def cache_put(cache, image, key, entry, keep=8):
    entry = dict(entry)
    entry["ts"] = int(__import__("time").time())
    builds = cache.setdefault("images", {}).setdefault(image, {}).setdefault("builds", {})
    builds[key] = entry
    while len(builds) > keep:                     # drop the oldest builds
        oldest = sorted(builds, key=lambda k: builds[k].get("ts", 0))[0]
        builds.pop(oldest)


def save_cache(path, cache):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


# ---------------------------------------------------------------- main
def main(argv):
    global log
    args = argv[1:]
    target = None
    opts = dict(sites=DEFAULT_SITES, slide="none", wm_slide=None, use_cache=True,
                cache_dir=None, skylight=SKYLIGHT, quiet=False)
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a == "--sites":
            i += 1
            opts["sites"] = args[i]
        elif a == "--no-cache":
            opts["use_cache"] = False
        elif a == "--slide":
            i += 1
            opts["slide"] = args[i]
        elif a == "--wm-slide":
            i += 1
            opts["wm_slide"] = int(args[i], 0)
        elif a == "--cache-dir":
            i += 1
            opts["cache_dir"] = args[i]
        elif a == "--skylight-image":
            i += 1
            opts["skylight"] = args[i]
        elif a == "--quiet":
            opts["quiet"] = True
        elif a.startswith("-"):
            log("wmlocate: unknown option %s" % a)
            return 2
        else:
            target = a
        i += 1
    if opts["quiet"]:
        log = lambda *a: None

    if target is None or target == "live":
        target = WM_LIVE
    if os.path.isdir(target):
        cand = os.path.join(target, "Contents", "MacOS", os.path.basename(target).replace(".app", ""))
        target = cand if os.path.exists(cand) else os.path.join(target, "WindowManager")

    result = dict(ok=False, target=target, sites={}, images={}, cache="miss",
                  refusals=[], slide=None)
    try:
        wm, slice_off = FatOrThin.open(target)
    except Exception as e:
        log("wmlocate: %s" % e)
        result["refusals"].append(dict(site="target", why=str(e)))
        print(json.dumps(result, indent=1, sort_keys=True))
        return 2

    if slice_off:
        result["slice_offset"] = slice_off
    version = bundle_version(target)
    wm_key = "%s|%s" % (version or "?", text_sha256(wm))
    cache = load_cache(opts["sites"]) if opts["use_cache"] else {"version": 1, "images": {}}
    entry = cache_get(cache, "WindowManager", wm_key) or {}
    sites = None
    ev = {}
    wm_cache = "miss"
    if entry.get("sites"):
        ok, why = verify_wm(wm, entry["sites"])
        if ok:
            sites = {k: int(v) for k, v in entry["sites"].items()}
            ev = entry.get("evidence", {})
            wm_cache = "hit-verified"
            log("wmlocate: sites.json hit for WindowManager %s (%s); re-verified" % (version, wm_key[:18]))
        else:
            log("wmlocate: sites.json entry rejected (%s); rescanning" % why)
    try:
        if sites is None:
            sites, ev, extra = find_wm_sites(wm)
            ok, why = verify_wm(wm, sites)
            if not ok:
                raise Refuse("WindowManager", "self-verification failed: %s" % why)
            cache_put(cache, "WindowManager", wm_key, dict(
                build=version, text_sha256=wm_key.split("|")[1],
                sites={k: sites[k] for k in sites}, evidence=ev, extra=extra))
            if opts["use_cache"]:
                save_cache(opts["sites"], cache)
    except Refuse as r:
        result["refusals"].append(dict(site=r.site, why=r.why))
        log("wmlocate: REFUSING %s: %s" % (r.site, r.why))

    wm_slide = opts["wm_slide"]
    if sites:
        for k in ("birth", "birth2", "birthE", "compute"):
            result["sites"][k] = dict(file_va=sites[k], file_va_hex=hex(sites[k]),
                                      live_va=(sites[k] + wm_slide) if wm_slide else None,
                                      image="WindowManager",
                                      evidence=ev.get(k, []),
                                      confidence=1.0)

    # ---- SkyLight
    cdir = opts["cache_dir"]
    if not cdir:
        for d in CACHE_DIRS:
            if os.path.exists(os.path.join(d, "dyld_shared_cache_arm64e")):
                cdir = d
                break
    try:
        if not cdir:
            raise Refuse("skylight", "no dyld shared cache directory found")
        cacheobj = SharedCache(cdir)
        entry = cache_get_by(cache, "SkyLight", "cache_uuid", cacheobj.uuid) or {}
        sl_cache = "miss"
        sl_sites = None
        sl_ev = {}
        img = None
        sl_key = None
        sl_sha = entry.get("text_sha256")
        # fast path: the cache UUID identifies the build, so the entry can be verified
        # from the 12 prologue bytes at the recorded addresses without scanning images
        if entry.get("sites") and entry.get("text_lo") and entry.get("text_hi"):
            lo, hi = int(entry["text_lo"]), int(entry["text_hi"])
            cand = {k: int(v) for k, v in entry["sites"].items()}
            ok = all(k in cand and lo <= cand[k] < hi and
                     keeper_shape_words(struct.unpack(
                         "<3I", cacheobj.read(cand[k], 12) or b"\0" * 12))
                     for k in ("keeper3d", "keeper2d"))
            if ok:
                sl_sites = cand
                sl_ev = entry.get("evidence", {})
                sl_key = "%s|%s" % (cacheobj.uuid, sl_sha)
                sl_cache = "hit-verified"
                log("wmlocate: sites.json hit for SkyLight (cache %s); re-verified from bytes"
                    % cacheobj.uuid[:12])
            else:
                log("wmlocate: SkyLight cache entry rejected (bytes no longer match); rescanning")
        if sl_sites is None:
            img = cacheobj.image(opts["skylight"])
            sl_sha = text_sha256(img)
            sl_key = "%s|%s" % (cacheobj.uuid, sl_sha)
            sl_sites, sl_ev = find_skylight_sites(cacheobj, opts["skylight"])
            ok, why = verify_sl(img, sl_sites)
            if not ok:
                raise Refuse("skylight", "self-verification failed: %s" % why)
            text = img.section(*TEXT)
            cache_put(cache, "SkyLight", sl_key, dict(
                build=cacheobj.uuid, cache_uuid=cacheobj.uuid,
                text_sha256=sl_sha,
                image_base=img.base, text_lo=text["addr"],
                text_hi=text["addr"] + text["size"],
                sites={k: sl_sites[k] for k in sl_sites}, evidence=sl_ev))
            if opts["use_cache"]:
                save_cache(opts["sites"], cache)
        # cache slide: unslid VAs are the durable identity; the boot slide maps them live
        slide = 0
        if opts["slide"] != "none":
            if opts["slide"] == "auto":
                slide = boot_cache_slide(cacheobj.mappings[0]["addr"])
                if slide is None:
                    raise Refuse("skylight", "cannot determine this boot's cache slide")
            else:
                slide = int(opts["slide"], 0)
            result["slide"] = slide
        ibase = img.base if img is not None else entry.get("image_base")
        result["images"]["SkyLight"] = dict(path=opts["skylight"], build=cacheobj.uuid,
                                            text_sha256=sl_sha,
                                            base=ibase, va_kind="unslid-cache",
                                            cache=sl_cache)
        for k in ("keeper3d", "keeper2d"):
            result["sites"][k] = dict(file_va=sl_sites[k], file_va_hex=hex(sl_sites[k]),
                                      live_va=(sl_sites[k] + slide) if slide else None,
                                      image="SkyLight", evidence=sl_ev.get(k, []),
                                      confidence=0.9 if "note:" in " ".join(sl_ev.get(k, [])) else 1.0)
    except Refuse as r:
        result["refusals"].append(dict(site=r.site, why=r.why))
        log("wmlocate: REFUSING %s: %s" % (r.site, r.why))

    result["images"]["WindowManager"] = dict(path=target, build=version,
                                             text_sha256=wm_key.split("|")[1],
                                             base=wm.base, va_kind="file",
                                             cache=wm_cache)
    result["cache"] = ("hit-verified"
                       if wm_cache == "hit-verified"
                       and result["images"].get("SkyLight", {}).get("cache") == "hit-verified"
                       else "miss")
    missing = [k for k in SITE_NAMES if k not in result["sites"]]
    result["ok"] = not missing
    result["missing"] = missing
    print(json.dumps(result, indent=1, sort_keys=True))
    if missing:
        log("wmlocate: FAILED, unresolved: %s" % ", ".join(missing))
        return 1
    log("wmlocate: all six sites located")
    return 0


def boot_cache_slide(unslid_base):
    """This boot's shared-cache slide, from a throwaway dyld, not from any target.

    The cache is mapped at `unslid_base + slide` in every process;
    `_dyld_get_shared_cache_range` in a fresh process returns that base.  No task port,
    no ptrace, no WindowManager contact - the helper is a bare `python3 -c`.
    """
    try:
        out = subprocess.run(
            ["/usr/bin/python3", "-c",
             "import ctypes;l=ctypes.CDLL(None);"
             "l._dyld_get_shared_cache_range.restype=ctypes.c_void_p;"
             "n=ctypes.c_size_t(0);p=l._dyld_get_shared_cache_range(ctypes.byref(n));"
             "print(p)"],
            capture_output=True, text=True, timeout=20)
        if out.returncode != 0 or not out.stdout.strip():
            return None
        base = int(out.stdout.strip(), 0)
        slide = base - unslid_base
        if slide < 0 or slide % 0x4000:
            return None
        return slide
    except Exception:
        return None


if __name__ == "__main__":
    sys.exit(main(sys.argv))
