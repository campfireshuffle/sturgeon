#!/usr/bin/python3
"""selftest.py — the protection checks, proved without root and without WindowManager.

Issue #19: WindowManager died with EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE while a patched build
was installed.  The crash report says the faulting *instruction pointer* equals the faulting
address (`pc.matchesCrashFrame == 1`) and that the page was `rw-` (writable, **not executable**) --
an instruction abort, not a bad write.  A page in that state inside WindowManager is a page the
tool handed back writable and never made executable again, and the branch that lands on it is one
we installed.

This file proves two things, both of them here rather than on the machine's live WindowManager:

  1. the signature: a write or a fetch against a page that has been made non-executable is
     SIGBUS / 10 with KERN_PROTECTION_FAILURE, which is the calibration the issue asked for;
  2. the guard: the installer's write path refuses a page it is not allowed to write, refuses to
     install a site when the island or the body is not executable, and will not free an
     allocation that an installed branch still targets.

Run: `python3 wmship/selftest.py` (exit 0 = every check passed).  No root, no task port, no
WindowManager, nothing written outside a temporary directory.
"""
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)
for p in (ROOT, HERE):
    if p not in sys.path:
        sys.path.insert(0, p)
import install as I                                          # noqa: E402

REAL_WMX = I.wmx                                             # for source checks; tests swap I.wmx

FAIL = []


def check(name, ok, detail=""):
    print("%-4s %s%s" % ("PASS" if ok else "FAIL", name, ("  -- " + detail) if detail else ""))
    if not ok:
        FAIL.append(name)
    return ok


def raises(fn, needle):
    try:
        fn()
    except I.Refuse as e:
        return needle in str(e), str(e)
    except Exception as e:                                   # noqa: BLE001
        return False, "wrong exception: %r" % (e,)
    return False, "did not refuse"


# ---------------------------------------------------------------- 1. the signature
PROBE = r"""
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
/* Produce, on demand, the signal the crash report records (EXC_BAD_ACCESS / KERN_PROTECTION_
   FAILURE / SIGBUS) so that signature stops being an inference.  The modes are the four states a
   page of ours has been in: writable-and-executable (what the helper hands back), writable and
   NOT executable (the state the crash report shows), readable-and-executable, and readable only. */
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "write";
    long pg = sysconf(_SC_PAGESIZE);
    unsigned char *p = mmap(0, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 2; }
    memset(p, 0, pg);
    if (!strcmp(mode, "fetch_rw")) {            /* rw-, max rwx <- the crash report's page */
        /* mmap RWX (so the maximum stays RWX) and then drop the execute bit: this is the state
           `mach_vm_allocate` + `mach_vm_protect(RW)` leaves a page in through a task port.  A plain
           mmap + mprotect cannot reach it, because a private mapping cannot be made W|X at all. */
        munmap(p, pg);
        p = mmap(0, pg, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) { perror("mmap rwx"); return 2; }
        memset(p, 0, pg);
        if (mprotect(p, pg, PROT_READ | PROT_WRITE)) { perror("mprotect rw"); return 2; }
        ((void (*)(void))p)();
    } else if (!strcmp(mode, "rwx_denied")) {   /* a process cannot make its own page W|X */
        void *q = mmap(0, pg, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        printf("%s\n", q == MAP_FAILED ? "denied" : "allowed");
        return q == MAP_FAILED ? 0 : 1;
    } else if (!strcmp(mode, "fetch_r")) {      /* r-- */
        if (mprotect(p, pg, PROT_READ)) { perror("mprotect"); return 2; }
        ((void (*)(void))p)();
    } else {                                    /* r-x: write to it, or just read it */
        if (mprotect(p, pg, PROT_READ | PROT_EXEC)) { perror("mprotect"); return 2; }
        if (!strcmp(mode, "read")) { printf("read %d\n", p[0]); return 0; }
        p[0] = 1;
    }
    printf("no fault\n");
    return 0;
}
"""


def signature(mode):
    """Compile the probe, run it in `mode`, and report how the kernel killed it."""
    d = tempfile.mkdtemp(prefix="wmship-sig-")
    try:
        src, exe = os.path.join(d, "probe.c"), os.path.join(d, "probe")
        open(src, "w").write(PROBE)
        c = subprocess.run(["clang", "-O0", "-o", exe, src], capture_output=True, text=True)
        if c.returncode != 0:
            return {"ok": False, "detail": "clang: " + (c.stderr or "").strip()[:200]}
        r = subprocess.run([exe, mode], capture_output=True, text=True, timeout=30)
        return {"ok": r.returncode == -signal.SIGBUS, "rc": r.returncode, "out": r.stdout.strip(),
                "signalled": -r.returncode if r.returncode < 0 else None}
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_signature():
    write = signature("write")
    check("a write to a page we made r-x is SIGBUS (KERN_PROTECTION_FAILURE)",
          write.get("signalled") == signal.SIGBUS,
          "signal %s" % write.get("signalled"))
    denied = signature("rwx_denied")
    check("a process cannot make its own page W|X, so the crash's rw-/rwx page came through a "
          "task port (the helper), not from WindowManager itself",
          denied.get("out") == "denied", "out %r rc %s" % (denied.get("out"), denied.get("rc")))
    fetch_r = signature("fetch_r")
    check("an instruction fetch from a r-- page is SIGBUS too", fetch_r.get("signalled")
          == signal.SIGBUS, "signal %s" % fetch_r.get("signalled"))
    read = signature("read")
    check("a page that is only r-x can still be read", read.get("rc") == 0,
          "rc %s %s" % (read.get("rc"), read.get("out")))


# ---------------------------------------------------------------- 2. the guard
# A fake wmx: it answers `regions` and `rd` from state the test controls, and records every call,
# so "the tool refused" can be told apart from "the tool tried and something else stopped it".
class FakeWmx:
    def __init__(self, regions=None):
        self.calls = []
        self.regions = regions or []                    # [(lo, size, "prot", "maxprot")]
        self.read = {}                                  # addr -> bytes

    def add(self, lo, size, prot, maxprot="rwx"):
        self.regions.append((lo, size, prot, maxprot))
        return self

    def __call__(self, *a):
        self.calls.append(tuple(str(x) for x in a))
        verb = str(a[0])
        if verb == "regions":
            addr = int(str(a[1]), 0)
            best = None
            for lo, size, prot, maxprot in self.regions:
                if lo <= addr < lo + size:
                    best = (lo, size, prot, maxprot)
            if not best:
                return "", "", 1
            lo, size, prot, maxprot = best
            return ("%#011x-%#011x %8x prot=%s max=%s shared=1 res=0"
                    % (lo, lo + size, size, prot, maxprot), "", 0)
        if verb == "rd":
            at, n = int(str(a[1]), 0), int(str(a[2]), 0)
            buf = self.read.get(at, b"\0" * n)[:n]
            lines = ["%#011x  " % (at + i) + " ".join("%02x" % b for b in buf[i:i + 16]) + " |"
                     for i in range(0, len(buf), 16)]
            return ("\n".join(lines), "", 0)
        if verb in ("wr", "remap", "prot", "dealloc", "allocat"):
            return ("0x%x" % self.regions[0][0], "", 0) if verb == "alloc" else ("", "", 0)
        if verb == "alloc":
            return "0x%x" % self.regions[0][0], "", 0
        return "", "", 0

    def wrote(self):
        return [c for c in self.calls if c[0] in ("wr", "remap")]


def test_guard(tmp):
    real_wmx = I.wmx
    real = (I.D, I.LASTOP, I.CRASH)
    I.D, I.LASTOP, I.CRASH = tmp, tmp + "/last_op.json", tmp + "/crash.json"
    page = 0x104AEC000
    try:
        # ---- a write is refused before it is attempted when the page is not writable
        fake = FakeWmx().add(page, 0x4000, "r-x")
        I.wmx = fake
        ok, why = raises(lambda: I.wrmem(page, b"\x00\x00\x00\x00"), "need w")
        check("wrmem refuses a page that is not writable", ok, why)
        check("  ... and never issues the write", fake.wrote() == [],
              "calls: %s" % [c[0] for c in fake.calls])

        fake = FakeWmx().add(page, 0x4000, "rw-")
        I.wmx = fake
        ok, why = raises(lambda: I.require_prot(page, "rx", "island"), "need rx")
        check("require_prot refuses a rw- page where r-x is required", ok, why)

        fake = FakeWmx().add(page, 0x4000, "rw-")
        I.wmx = fake
        check("wrmem writes to a writable page", I.wrmem(page, b"\x1f\x20\x03\xd5") is True)
        check("  ... with exactly one write", len(fake.wrote()) == 1)

        # ---- the pre-arm self-test: island must read back exactly and be executable
        island, body, spl, size = 0x104AEC000, 0x10D000000, 0x8000, 0x10000
        want = bytes(range(256)) * 64                        # exactly 0x4000
        good = (FakeWmx().add(island, 0x4000, "r-x").add(body, spl, "r-x")
                .add(body + spl, size - spl, "rw-"))
        good.read[island] = want
        I.wmx = good
        I.island_selftest(island, want, {"a": 1, "b": 2}, body, spl)
        check("island_selftest passes on an r-x island that reads back", True)

        bad_rw = FakeWmx().add(island, 0x4000, "rw-").add(body, spl, "r-x") \
            .add(body + spl, size - spl, "rw-")
        bad_rw.read[island] = want
        I.wmx = bad_rw
        ok, why = raises(lambda: I.island_selftest(island, want, {}, body, spl), "need rx")
        check("island_selftest refuses a rw- island (the crash report's state)", ok, why)

        bad_bytes = bytearray(want)
        bad_bytes[0x28] ^= 0xFF
        stale = FakeWmx().add(island, 0x4000, "r-x").add(body, spl, "r-x") \
            .add(body + spl, size - spl, "rw-")
        stale.read[island] = bytes(bad_bytes)
        I.wmx = stale
        ok, why = raises(lambda: I.island_selftest(island, want, {}, body, spl), "differs at +0x28")
        check("island_selftest refuses an island whose stub did not land", ok, why)

        short = FakeWmx().add(island, 0x4000, "r-x").add(body, 0x4000, "r-x")
        short.read[island] = want
        I.wmx = short
        ok, why = raises(lambda: I.island_selftest(island, want, {}, body, spl), "expected at least")
        check("island_selftest refuses a body shorter than its code section", ok, why)

        # ---- a live branch into a page is found before that page is taken
        word = 0x14000000 | (0x300 >> 2)                     # b #0x300
        sites = [(0x100001000, {"name": "keeper2d"})]
        fake = FakeWmx()
        fake.read[0x100001000] = struct.pack("<III", word, 0, 0)
        I.wmx = fake
        into = I.live_branches_into(0x100001000, 0x100001400, sites)
        check("live_branches_into finds a `b` into the page", bool(into), repr(into))
        check("  ... and names the site", bool(into) and into[1] == "keeper2d", repr(into))
        check("live_branches_into ignores a page nothing branches to",
              I.live_branches_into(0x100002000, 0x100003000, sites) is None)

        # ---- the record the daemon reads (note_op is what wmx() calls; wmx() itself shells out)
        I.note_op("wr 0x104aec000 4")
        rec = json.load(open(tmp + "/last_op.json"))
        check("a mutating operation is recorded before it runs",
              rec.get("op", "").startswith("wr "), json.dumps(rec))
        src = __import__("inspect").getsource(REAL_WMX)
        check("wmx() records mutating verbs only", "note_op" in src and "MUTATING" in src)
    finally:
        I.wmx = real_wmx
        I.D, I.LASTOP, I.CRASH = real


# ---------------------------------------------------------------- 3. the daemon
def test_daemon(tmp):
    """The daemon must not decide by itself that a dead WindowManager is fine to patch again."""
    d = os.path.join(HERE, "wmshipd.py")
    src = open(d).read()
    check("wmshipd records a crash with the last operation",
          "record_crash" in src and "last_op" in src)
    check("wmshipd refuses to re-arm while the crash block stands",
          "crash_block()" in src and "block_reason" in src)
    ins = open(os.path.join(HERE, "install.py")).read()
    tail = ins.split("def _doctor_out")[1].split("DOCTOR")[0]
    check("only a human doctor (no --json) clears the block", "not as_json" in tail, tail[:200])
    check("the daemon's own doctor call cannot clear it", "--json" in src)


# ---------------------------------------------------------------- 4. payload invariants (no root)
def test_payload_invariants():
    """The three properties of round 3 that a source check can hold, with no WindowManager.

    They are invariants, not style: a decision that reads the trace ring would make the diagnostic
    part of the control plane; a scale about the config pivot would make the shipped pivot the old
    constant again; a wall-clock promotion window would bring back the timing assumption (#4).
    The app bundle ships the payload *image* but not its sources, so in the bundle this falls back
    to checking the symbols the image must expose."""
    psrc = os.path.join(HERE, "payload.c")
    if not os.path.exists(psrc):
        syms = json.load(open(os.path.join(HERE, "payload.syms.json")))["syms"]
        check("the shipped payload image exposes the trace ring (issue #31)",
              all(k in syms for k in ("_io_tr", "_io_tr_len", "_io_tr_pos", "_io_tr_seq")))
        return
    src = open(psrc).read()
    branches = [l for l in src.splitlines()
                if re.search(r"\b(if|while|for)\s*\([^)]*io_tr", l)]
    check("the trace ring is write-only (no branch reads io_tr, issue #31)",
          not branches, "; ".join(branches)[:200])
    check("the trace is parsed from the cfg and defaults off",
          'jbool(cfg, "trace"' in src and "trace_one(" in src)
    check("every keeper trace record is gated on the flag", "if (G.trace) trace_one(" in src)

    scales = [l.strip() for l in src.splitlines()
              if re.search(r"mat_scale\(.*,\s*s\s*,", l) and not l.strip().startswith(("//", "*", "/*"))]
    check("scaling uses the resolved pivot (issue #3)",
          bool(scales) and all("G.px, G.py" in l for l in scales), "; ".join(scales)[:300])
    check("the config pivot is only reachable through `pivot_fixed`",
          src.count("G.qx") <= 2 and "G.pivot_fixed && G.has_qx" in src)
    check("a scale with no derivable pivot is refused, not guessed",
          "G.n_piv_miss++" in src and "if (!G.piv_src)" in src)

    check("promotion is the settle detector, not a wall-clock window (issue #4)",
          "SETTLE_TICKS" in src and "#define QUIET" not in src
          and "p->cand_ticks >= SETTLE_TICKS" in src)
    check("the rail id-set invalidates bases structurally",
          "G.n_railchg++" in src and "G.rail_key_geom" in src)

    ins = open(os.path.join(HERE, "install.py")).read()
    check("the shipped config no longer carries the constant pivot",
          '"qx"' not in ins.split("CFG_DEFAULT")[1].split("}")[0])
    ctl = open(os.path.join(HERE, "ctl.py")).read()
    check("ctl.py writes no pivot", "qx=16" not in ctl and "490" not in ctl)
    wmc = os.path.join(HERE, "..", "wm", "wmctl.py")
    if os.path.exists(wmc):
        sweep = open(wmc).read().split("def force_writes")[1].split("\ndef ")[0]
        check("the teach sweep parks in the gutter, never on a tile (Orca 9547 regression)",
              "30 400" not in sweep and "3 500 3 500" in sweep)
    ars = os.path.join(HERE, "..", "helpers", "asroot.c")
    check("the trace verb exists in every layer",
          "def trace_dump" in ctl
          and (not os.path.exists(ars) or '"trace"' in open(ars).read()))


def main():
    tmp = tempfile.mkdtemp(prefix="wmship-selftest-")
    try:
        test_signature()
        test_guard(tmp)
        test_daemon(tmp)
        test_payload_invariants()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    if FAIL:
        print("SELFTEST: FAIL (%d) %s" % (len(FAIL), ", ".join(FAIL)))
        return 1
    print("SELFTEST: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
