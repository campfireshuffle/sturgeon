#!/bin/zsh
# setup.sh — the one privileged step of an installed Sturgeon (run once, idempotent).
#
#   Sturgeon.app/Contents/Resources/wmship/setup.sh [--load] [--replace]
#
# It installs exactly two things, both derived from WHERE THIS FILE IS:
#
#   1. /etc/sudoers.d/stage-pilot   one line: <you> ALL=(root) NOPASSWD: <app>/…/bin/asroot
#      The tool needs root for task_for_pid, the LaunchDaemon and the page remap.  A single
#      NOPASSWD rule is used instead of prompting per operation because `wmship.sh start|stop`,
#      `doctor` and the daemon must run unattended (the daemon is a launchd job with no terminal
#      to prompt on).  No credential is stored: the rule grants one *compiled* binary that accepts
#      a fixed verb list (doctor/status/install/uninstall/arm/disarm/…) and refuses arbitrary
#      argv.  It is not a shell: there is no `sh -c`, no stdin and no inherited environment.
#   2. /Library/LaunchDaemons/com.stagemgr.wmshipd.plist
#      ProgramArguments are filled in for this bundle (a shipped plist with a baked-in path would
#      silently re-arm the wrong tree).  Installed, NOT started: `--load` starts it now, and
#      `wmship.sh start` starts it as part of arming.  launchd loads it at next boot either way.
#
# Idempotent: a working NOPASSWD rule is detected with `sudo -n <asroot> -c true` and left alone
# (no prompt); an identical plist is left alone.  It REFUSES when the path it would grant is not
# the path it is running from — i.e. a moved/copied app, or a rule that already names a different
# helper.  Override a stale foreign rule deliberately with --replace.
set -u
SELF=${0:A}                        # symlinks resolved: the rule must name this real location
R=${SELF:h}
PY=/usr/bin/python3
if [ ! -f $R/wmlayout.py ]; then
  print -r -- "setup: broken install — $R/wmlayout.py is missing" >&2
  exit 1
fi
eval "$($PY $R/wmlayout.py shell)" || exit 1

LOAD=0
REPLACE=0
for a in "$@"; do
  case $a in
    --load) LOAD=1 ;;
    --replace) REPLACE=1 ;;
    -h|--help) sed -n '2,20p' $SELF; exit 0 ;;
    *) print -r -- "setup: unknown option $a" >&2; exit 2 ;;
  esac
done

die() { print -r -- "setup: $*" >&2; exit 1; }

[ "$LAYOUT" = bundle ] || die "this is the development checkout ($ROOT); its rule is
  /etc/sudoers.d/stage-mgr and it is maintained by hand — setup.sh is for an installed app."

APP=$(cd $R/../../.. && pwd -P)          # <app>.app/Contents/Resources/wmship -> <app>.app
[[ $APP == *.app ]] || die "the tool is not inside a .app bundle: $APP"
GRANT=$APP/Contents/Resources/wmship/bin/asroot
[ -x $GRANT ] || die "$GRANT is missing or not executable"
# The rule grants a verb dispatcher, never a shell.  Refuse to grant a stale script copy (an
# older bundle, or a tree where the helper was not rebuilt).
"$GRANT" --verbs >/dev/null 2>&1 \
  || die "$GRANT is not the verb-limited helper (rebuild with scripts/build-helpers.sh, or
  reinstall the app)"
# the identity check the brief asks for: what we would grant must be what we are running
[ "$GRANT" = "$ASROOT" ] || die "refusing: the rule would grant
  $GRANT
  but this copy runs from
  $ASROOT
  (move the app as a whole, or run the setup.sh of the copy you want to use)"

STATE=$($PY $R/wmlayout.py state-dir) || die "cannot create the state directory"
mkdir -p $LOGS 2>/dev/null
say() {
  print -r -- "setup: $*"
  # the log may have been created by a root run; the subshell keeps zsh's redirection error quiet
  ( print -r -- "$(date '+%Y-%m-%dT%H:%M:%S') setup: $*" >> $LOGS/setup.log ) 2>/dev/null || true
}

# ---------------------------------------------------------------- what is already true
RULE_OK=0
if [ "$(id -u)" = 0 ]; then RULE_OK=1
elif sudo -n "$ASROOT" -c true >/dev/null 2>&1; then RULE_OK=1; fi

T=$(mktemp -d /tmp/stagepilot-setup.XXXXXX) || die "no scratch directory"
trap '/bin/rm -rf '"$T" EXIT INT TERM

# stages: the rule text, the plist — both plain files a root shell can install
print -r -- "$CONSOLE_USER ALL=(root) NOPASSWD: $GRANT" > $T/stage-pilot
$PY $R/wmlayout.py plist $T/wmshipd.plist || die "cannot render the LaunchDaemon plist"
chmod 0440 $T/stage-pilot
chmod 0644 $T/wmshipd.plist

PLIST_OK=0
cmp -s $T/wmshipd.plist $PLIST && PLIST_OK=1

if [ "$RULE_OK" = 1 ] && [ "$PLIST_OK" = 1 ] && [ "$LOAD" = 0 ]; then
  say "already set up: $SUDOERS grants $GRANT; $PLIST is current — nothing to do"
  exit 0
fi

# ---------------------------------------------------------------- the root-side script
# Everything privileged happens in one shell invocation, so there is at most one password prompt.
# It reports through $T/result (osascript turns a non-zero exit into a dialog, not a message).
cat > $T/plan.sh <<PLAN
SRC=$T
SUDOERS=$SUDOERS
PLIST=$PLIST
LABEL=$PLIST_LABEL
GRANT=$GRANT
REPLACE=$REPLACE
LOAD=$LOAD
PLAN
cat > $T/run.sh <<'RUN'
#!/bin/zsh
set -u
SRC=${0:A:h}
. "$SRC/plan.sh"
out=$SRC/result
: > $out
say() { print -r -- "$*" >> $out; }
if [ -f "$SUDOERS" ] && [ "$REPLACE" != 1 ]; then
  if grep -q 'NOPASSWD' "$SUDOERS" && ! grep -qF "$GRANT" "$SUDOERS"; then
    other=$(sed -n 's/.*NOPASSWD:[[:space:]]*//p' "$SUDOERS" | head -1)
    say "REFUSED: $SUDOERS already grants a different helper: $other"
    say "         run that copy's teardown.sh, or re-run setup.sh --replace"
    exit 0
  fi
fi
if /usr/sbin/visudo -c -f "$SRC/stage-pilot" >/dev/null 2>&1; then
  /usr/bin/install -m 0440 -o root -g wheel "$SRC/stage-pilot" "$SUDOERS" || { say "REFUSED: could not write $SUDOERS"; exit 0; }
  say "rule: $SUDOERS -> $GRANT"
else
  say "REFUSED: the generated sudoers line does not validate (visudo -c) — nothing written"
  exit 0
fi
if /usr/bin/cmp -s "$SRC/wmshipd.plist" "$PLIST"; then
  say "plist: unchanged"
else
  /usr/bin/install -m 0644 -o root -g wheel "$SRC/wmshipd.plist" "$PLIST" \
    && say "plist: $PLIST" || { say "REFUSED: could not write $PLIST"; exit 0; }
fi
if [ "$LOAD" = 1 ]; then
  /bin/launchctl bootout system/$LABEL 2>/dev/null
  if /bin/launchctl bootstrap system "$PLIST" 2>>$out; then say "daemon: loaded system/$LABEL"
  else say "daemon: could not be loaded (plist is installed; next boot or 'wmship.sh start')"; fi
fi
exit 0
RUN
chmod 0755 $T/run.sh

# the command string osascript sees contains one path and nothing else
ESCAPED=${T//\"/}
RC=0
if [ "$(id -u)" = 0 ]; then
  /bin/zsh $T/run.sh; RC=$?
else
  /usr/bin/osascript -e "do shell script \"/bin/zsh $ESCAPED/run.sh\" with administrator privileges" >/dev/null 2>&1 || RC=$?
fi

RES=$(cat $T/result 2>/dev/null)
if [ -z "$RES" ]; then
  say "FAILED: no result from the privileged step (canceled password prompt?)"
  exit 1
fi
print -r -- "$RES" | while IFS= read -r l; do say "$l"; done
case $RES in
  *REFUSED*) exit 1 ;;
  *"rule:"*|*"already"*|*"unchanged"*) ;;
esac

# prove the rule works before claiming success
if ! sudo -n "$ASROOT" -c true >/dev/null 2>&1; then
  say "WARNING: the rule was written but 'sudo -n $ASROOT' still fails — check /etc/sudoers.d syntax"
  exit 1
fi
[ "$(id -u)" = 0 ] && /usr/sbin/chown -R $CONSOLE_USER $STATE 2>/dev/null
say "ready: sudo -n $ASROOT works"
if [ "$LOAD" = 1 ]; then
  say "next: $R/wmship.sh status"
else
  say "next: $R/wmship.sh doctor && $R/wmship.sh start   (or launchd arms it at the next login)"
fi
exit 0
