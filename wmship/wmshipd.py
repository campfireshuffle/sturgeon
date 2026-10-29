#!/usr/bin/python3
"""wmshipd.py — the root LaunchDaemon: keep the patch applied across WindowManager restarts.

  * waits for WindowManager, then re-applies whenever the pid changes
  * runs `install.py doctor` BEFORE every re-apply and never patches blind: a doctor failure
    leaves the payload disarmed, publishes the reason and backs off instead of spinning
  * supervises the one helper (`wmhb`), which it starts after a successful install and stops
    when it exits, so `wmship.sh stop` leaves nothing behind
  * every 5 minutes, re-checks that the six sites still hold the patch; if they do not (someone
    restored them, or a stale state file), it goes through doctor again

Nothing here attaches a debugger: install.py uses task_for_pid only.  State is published in
/tmp/wmship/daemon.json and appended to /tmp/wmship/daemon.log.
"""
import json
import os
import signal
import subprocess
import sys
import time

# the tool tree this daemon was loaded from: the checkout (work/wmship) or the app
# (Sturgeon.app/Contents/Resources/wmship/wmship) — never a baked-in repository path
_HERE = os.path.dirname(os.path.realpath(__file__))
_ROOT = os.path.dirname(_HERE)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
import wmlayout as LAYOUT                                  # noqa: E402

W = LAYOUT.wmship_dir()
D = LAYOUT.layout()["runtime"]
PY = LAYOUT.PY
INSTALL = os.path.join(W, "install.py")
HELPER = os.path.join(W, "wmhb")
PROFILE = LAYOUT.profile_json()
LOG = D + "/daemon.log"
ST = D + "/daemon.json"
STATE = D + "/state.json"
MAP = D + "/map.txt"

_stop = False
helper = None


def log(m):
    try:
        os.makedirs(D, exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%.3f %s\n" % (time.time(), m))
    except Exception:
        pass


def publish(**kw):
    kw["t"] = time.time()
    try:
        with open(ST + ".tmp", "w") as f:
            json.dump(kw, f, indent=1)
        os.replace(ST + ".tmp", ST)
    except Exception:
        pass


def wm_pid():
    try:
        out = subprocess.run(["/usr/bin/pgrep", "-x", "WindowManager"],
                             capture_output=True, text=True, timeout=10).stdout.split()
        return int(out[0]) if out else 0
    except Exception:
        return 0


def run(args, t=300):
    r = subprocess.run([PY] + args, capture_output=True, text=True, timeout=t)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def profile_args():
    """The object-layout addresses for the helper: state.json's, cross-checked with profile.json."""
    try:
        s = json.load(open(STATE))
        wm, wt = s.get("widmeta"), s.get("widtable")
        key = s.get("profile_key") or ""
        ivr = ivc = 0
        try:
            b = (json.load(open(PROFILE)).get("builds") or {}).get(key) or {}
            ivr, ivc = b.get("ivar_reg", 0), b.get("ivar_comp", 0)
        except Exception:
            pass
        if wm and wt:
            return ["--map", MAP, "--widmeta", hex(wm), "--widtable", hex(wt),
                    "--ivar-reg", hex(ivr), "--ivar-comp", hex(ivc)]
    except Exception:
        pass
    return None


def ensure_helper():
    global helper
    if helper is not None and helper.poll() is None:
        return True
    a = profile_args()
    if not a:
        log("helper: no profile in state.json, not starting")
        return False
    if not os.path.exists(MAP):
        log("helper: no map file, not starting")
        return False
    helper = subprocess.Popen([HELPER] + a + ["--interval", "0.01"],
                              stdout=open(D + "/hb.out", "a"),
                              stderr=open(D + "/hb.err", "a"),
                              start_new_session=True)
    log("helper: started pid %d" % helper.pid)
    return True


def stop_helper():
    global helper
    if helper is not None and helper.poll() is None:
        try:
            helper.terminate()
            helper.wait(timeout=5)
        except Exception:
            try:
                helper.kill()
            except Exception:
                pass
        log("helper: stopped pid %d" % helper.pid)
    helper = None


def site_check():
    """Cheap read-back: are the six sites still ours? (install.py status reports it.)"""
    rc, out, err = run([INSTALL, "status"], 120)
    return rc == 0, (out or err).strip().split("\n")[-1]


def on_signal(sig, frame):
    global _stop
    _stop = True


def main():
    os.makedirs(D, exist_ok=True)
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    log("wmshipd start pid %d" % os.getpid())
    applied = 0
    armed = False
    fails = 0
    last_reason = ""
    t_check = 0.0
    try:
        s = json.load(open(STATE))
        applied = s.get("pid") or 0
        armed = bool(applied)
    except Exception:
        pass
    publish(state="armed" if armed else "starting", wm_pid=wm_pid(), armed=armed,
            reason="adopted the existing install" if armed else "")
    while not _stop:
        pid = wm_pid()
        if not pid:
            if applied:
                log("WindowManager gone")
                stop_helper()
            applied, armed, fails = 0, False, 0
            publish(state="disarmed", wm_pid=0, armed=False, reason="WindowManager not running")
            time.sleep(0.5)
            continue
        if pid != applied:
            # never patch blind: doctor resolves and validates every site, and verifies the
            # object-layout profile against this very process, before anything is written
            rc, out, err = run([INSTALL, "doctor", "--json"], 300)
            if rc != 0:
                fails += 1
                try:
                    rep = json.loads(out)
                    reason = (rep.get("refusals") or [""])[0] or \
                        "; ".join(c["check"] for c in rep.get("checks", []) if not c["ok"]) or err
                except Exception:
                    reason = (err or out or "doctor failed").strip().split("\n")[-1]
                if reason != last_reason or fails in (1, 5, 20):
                    log("DOCTOR FAILED pid=%d (%d): %s" % (pid, fails, reason[:400]))
                last_reason = reason
                publish(state="disarmed", wm_pid=pid, armed=False, fails=fails,
                        reason="doctor: " + reason[:400])
                if armed:
                    stop_helper()
                applied, armed = pid, False       # do not retry the same build every 0.5 s
                time.sleep(2.0 if fails < 5 else 10.0)
                continue
            rc, out, err = run([INSTALL, "install"], 300)
            if rc != 0:
                fails += 1
                reason = (err or out).strip().split("\n")[-1]
                if reason != last_reason or fails in (1, 5, 20):
                    log("INSTALL FAILED pid=%d (%d): %s" % (pid, fails, reason[:400]))
                last_reason = reason
                publish(state="disarmed", wm_pid=pid, armed=False, fails=fails,
                        reason="install: " + reason[:400])
                applied, armed = pid, False
                time.sleep(2.0 if fails < 5 else 10.0)
                continue
            applied, armed, fails, last_reason = pid, True, 0, ""
            log("ARMED pid=%d %s" % (pid, out.replace("\n", " | ")[:300]))
            ensure_helper()
            publish(state="armed", wm_pid=pid, armed=True, fails=0)
            t_check = time.time()
            continue
        if armed and time.time() - t_check > 300:
            t_check = time.time()
            ok, why = site_check()
            if not ok:
                log("SITES LOST pid=%d: %s" % (pid, why[:300]))
                publish(state="disarmed", wm_pid=pid, armed=False, reason="sites lost: " + why[:200])
                armed = False
                stop_helper()
                applied = 0                       # force a doctor-gated re-apply next pass
                continue
        if armed:
            ensure_helper()
        time.sleep(0.5)
    stop_helper()
    log("wmshipd stop")
    publish(state="stopped", wm_pid=wm_pid(), armed=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
