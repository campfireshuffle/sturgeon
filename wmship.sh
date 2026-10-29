#!/bin/zsh
# wmship — ONE user surface for the four Stage Manager capabilities, as an in-memory patch of
# WindowManager with no debugger anywhere.
#
#   wmship start              doctor, install, start the helper + observers, arm the daemon
#   wmship stop               disarm the daemon, stop helper/observers, restore every site
#   wmship status             build id, armed/disarmed, capabilities, debugger, processes
#   wmship move <stage>       move the frontmost window into <stage> ("current" or a tile title)
#   wmship resize <scale>     strip rendered scale 0.4 .. 1.5 (1.0 = natural)
#   wmship doctor             resolve + validate all six sites and the object-layout profile
#   wmship uninstall          stop, then remove the LaunchDaemon and every temp artefact
#
#   extras: wmship level 0|3 | warm | measure | teach | selfcheck | cfg | log [-f] | pristine |
#           restart
#
# The only persistent root process is /Library/LaunchDaemons/com.stagemgr.wmshipd.plist
# (wmshipd.py), and only while the patch is *armed*: `stop`/`uninstall` boot it out.  It exists
# so a WindowManager restart is re-applied automatically — and it runs `doctor` first every time,
# so it can never patch a build the locator does not fully understand.
#
# RELOCATION: every path below is resolved by wmlayout.py from this script's own location, so the
# same script runs from the development checkout (<repo>/work) and from
# Sturgeon.app/Contents/Resources/wmship.  The only absolute paths left are the fixed system
# locations: /tmp/wmship (runtime state) and /Library/LaunchDaemons (the daemon).
#
# Requirements: SIP off, root (setup.sh installs the NOPASSWD rule for the bundled bin/asroot,
# a compiled helper limited to fixed verbs),
# macOS 27.0.1 / WindowManager 462.0.8.402 (other builds need a layout profile — `doctor` says so).
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SELF=${0:A}                       # absolute, symlinks resolved: the sudoers rule names one path
R=${SELF:h}
if [ ! -f $R/wmlayout.py ]; then
  echo "wmship: broken install — $R/wmlayout.py is missing (reinstall the app)" >&2
  exit 1
fi
PY=/usr/bin/python3
eval "$($PY $R/wmlayout.py shell)" || { echo "wmship: wmlayout failed" >&2; exit 1; }
S=$WMSHIP
LABEL=$PLIST_LABEL

have_root() {
  [ "$(id -u)" = 0 ] && return 0
  sudo -n "$ASROOT" probe >/dev/null 2>&1
}
# bin/asroot is a compiled, verb-limited dispatcher: it accepts a fixed verb list and never runs
# a shell command.  The root probe is its own verb (`probe`); the app's three legacy `-c`
# shapes are accepted only by legacy_command().
asroot() { if [ "$(id -u)" = 0 ]; then "$ASROOT" "$@"; else sudo -n "$ASROOT" "$@"; fi; }
need_root() {
  if ! have_root; then
    echo "wmship: no root — '$ASROOT' is not NOPASSWD. Install the rule (admin password once):"
    echo "  $PY $R/wmlayout.py sudoers-line"
    echo "  ...written to $SUDOERS (or run $R/setup.sh, which does it for you)"
    exit 1
  fi
}
# /tmp/wmship is the helper's state directory.  Read-only commands must not create it (a user-run
# `status` used to recreate it as an empty user-owned directory after `uninstall` had removed it).
case "${1:-status}" in
  status|doctor|pristine|log|selfcheck) : ;;
  *) mkdir -p $D; chmod 777 $D 2>/dev/null ;;
esac

# a debugger must never be part of this mode; refuse before touching anything
debugger_guard() {
  if pgrep -x lldb >/dev/null 2>&1 || pgrep -f Resources/debugserver >/dev/null 2>&1; then
    echo "wmship: an lldb/debugserver is running; this mode is debugger-free by construction."
    echo "        stop the debugger session first (work/wmctl.sh stop), then retry."
    exit 1
  fi
}

observers_start() {
  local U=$(stat -f%Su /dev/console)
  local O1=$WMOBS O2=$R21OBS
  pgrep -x wmobs >/dev/null 2>&1 || \
    ( if [ "$(id -un)" = "$U" ]; then cd ${O1:h} && nohup ./${O1:t} >/dev/null 2>&1 &
      else sudo -u "$U" /bin/zsh -c "cd $(printf '%q' ${O1:h}) && nohup ./$(printf '%q' ${O1:t}) >/dev/null 2>&1 &"; fi )
  pgrep -x r21obs >/dev/null 2>&1 || \
    ( if [ "$(id -un)" = "$U" ]; then cd ${O2:h} && nohup ./${O2:t} --out /tmp/wm/state.json >/dev/null 2>&1 &
      else sudo -u "$U" /bin/zsh -c "cd $(printf '%q' ${O2:h}) && nohup ./$(printf '%q' ${O2:t}) --out /tmp/wm/state.json >/dev/null 2>&1 &"; fi )
  sleep 0.8
}
observers_stop() {
  pkill -x wmobs 2>/dev/null
  pkill -x r21obs 2>/dev/null
  sleep 0.2
}
# The plist is generated from this location on every load: a shipped plist with a baked-in
# ProgramArguments path is the relocation bug, not a convenience.  The root-side rendering,
# mode/owner and relocation check all live in bin/asroot (verb `daemon-load`) so no shell
# command ever runs as root.
daemon_load() {
  asroot daemon-load
}
daemon_unload() {
  asroot daemon-unload
  pkill -x wmhb 2>/dev/null
  sleep 0.3
}

case "${1:-status}" in
  start)
    need_root; debugger_guard
    # Idempotent: already armed from this exact payload image is a no-op.  `doctor` can validate an
    # armed install too (`--mode armed`, chosen automatically), but re-arming from an armed state
    # is not what this branch is for: it keeps `start` from restoring a payload that is already
    # resident (round 34).
    SAME=$($PY - "$D/state.json" "$S/payload.img" <<'PYEOF'
import hashlib, json, sys
try:
    print(1 if json.load(open(sys.argv[1])).get("img_sha256")
          == hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest() else 0)
except Exception:
    print(0)
PYEOF
)
    if [ "$SAME" = "1" ] && asroot status 2>/dev/null | grep -q "^state: *ARMED"; then
      observers_start
      daemon_load || echo "wmship: warning — could not load the LaunchDaemon"
      echo "== already armed with this payload image =="
      asroot status 2>/dev/null || true
      exit 0
    fi
    if [ "$SAME" = "0" ] && asroot status 2>/dev/null | grep -q "^state: *ARMED"; then
      # A rebuilt payload must not be doctor-tested against our own live patch: restore first.
      echo "== payload image changed — restoring the pristine sites before the doctor =="
      asroot uninstall >/dev/null 2>&1 || true
    fi
    echo "== doctor =="
    asroot doctor || { echo "wmship: doctor refused — nothing installed."; exit 1; }
    echo "== install =="
    asroot install || { echo "wmship: install failed."; exit 1; }
    observers_start
    daemon_load || { echo "wmship: could not load the LaunchDaemon"; exit 1; }
    for i in $(seq 1 40); do
      sleep 0.25
      pgrep -x wmhb >/dev/null 2>&1 && break
    done
    echo "== status =="
    asroot status
    ;;
  stop)
    need_root
    daemon_unload
    observers_stop
    asroot uninstall
    pkill -x wmhb 2>/dev/null
    echo "== pristine =="
    asroot pristine
    echo "lldb: '$(pgrep -x lldb | tr '\n' ' ')'  debugserver: '$(pgrep -f Resources/debugserver | tr '\n' ' ')'  (must be empty)"
    echo "left: wmhb='$(pgrep -x wmhb | tr '\n' ' ')' wmobs='$(pgrep -x wmobs | tr '\n' ' ')' r21obs='$(pgrep -x r21obs | tr '\n' ' ')' wmshipd='$(pgrep -f wmshipd.py | tr '\n' ' ')'  (must be empty)"
    ;;
  restart)
    "$0" stop; sleep 0.5; "$0" start ;;
  status)
    need_root
    asroot status
    if asroot daemon-status >/dev/null 2>&1; then
      echo "launchd: system/$LABEL loaded"
    else
      echo "launchd: system/$LABEL not loaded (no automatic re-apply)"
    fi
    ;;
  doctor)
    need_root
    shift
    asroot doctor "$@"
    ;;
  pristine)
    need_root
    asroot pristine
    ;;
  move)
    need_root; shift
    asroot move "${1:-current}" "${@:2}"
    ;;
  resize)
    need_root; shift
    asroot resize "${1:-1.0}" "${@:2}"
    ;;
  teach)
    need_root; shift
    asroot teach
    ;;
  selfcheck)
    need_root
    asroot selfcheck
    ;;
  level)
    need_root; shift
    asroot level "${1:-0}"
    ;;
  warm|measure|cfg|state|poses)
    need_root
    asroot "$1"
    ;;
  log)
    if [ "${2:-}" = "-f" ]; then tail -f $D/install.log $D/daemon.log $D/hb.err 2>/dev/null
    else echo "--- install"; tail -12 $D/install.log 2>/dev/null
         echo "--- daemon"; tail -8 $D/daemon.log 2>/dev/null
         echo "--- payload"; asroot log 2>/dev/null | tail -12
    fi ;;
  uninstall)
    need_root
    "$0" stop || exit 1
    asroot daemon-unload >/dev/null 2>&1
    # D is root-owned once the daemon has run, so removing it needs root too; and only claim it
    # was removed when it actually was (round 34: `rm -rf` as the user failed silently and the
    # script still printed "removed").
    if asroot remove-state && [ ! -e $D ]; then
      echo "uninstalled: daemon + plist removed, $D removed, WindowManager pristine."
    else
      echo "uninstalled: daemon + plist removed, WindowManager pristine; WARNING: $D could not be removed (still present)"
    fi
    echo "kept (durable, inert): $SITES (site cache) and $PROFILE (build profiles)."
    echo "the NOPASSWD rule stays in $SUDOERS — remove it with $R/teardown.sh."
    ;;
  *)
    echo "usage: wmship start|stop|status|move <stage>|resize <scale>|doctor|uninstall"
    echo "       extras: restart|level 0|3|warm|measure|state|cfg|log [-f]|pristine|teach|selfcheck"
    exit 1 ;;
esac
