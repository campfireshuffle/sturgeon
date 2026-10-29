#!/bin/zsh
# teardown.sh — remove the two privileged pieces of an installed Sturgeon (idempotent).
#
#   Sturgeon.app/Contents/Resources/wmship/teardown.sh [--keep-state]
#
#   1. boot out and delete /Library/LaunchDaemons/com.stagemgr.wmshipd.plist
#      (and the helper it spawned — the patch itself is removed by `wmship.sh stop`)
#   2. delete /etc/sudoers.d/stage-pilot — but ONLY if it grants this bundle's bin/asroot
#   3. delete /tmp/wmship (root-owned runtime state) unless --keep-state
#
# The user caches in ~/Library/Application Support/Sturgeon are NOT touched: an uninstall without
# `zap` keeps them, exactly like the cask's `zap` stanza describes.
#
# Elevation order: already root, then the tool's own NOPASSWD helper (so `brew uninstall` needs no
# password while the app is still allowed), then one administrator prompt.  Nothing is stored.
# It refuses when the rule it would delete names a different helper than the one running.
set -u
SELF=${0:A}
R=${SELF:h}
PY=/usr/bin/python3
if [ ! -f $R/wmlayout.py ]; then
  print -r -- "teardown: broken install — $R/wmlayout.py is missing" >&2
  exit 1
fi
eval "$($PY $R/wmlayout.py shell)" || exit 1

KEEP=0
for a in "$@"; do
  case $a in
    --keep-state) KEEP=1 ;;
    -h|--help) sed -n '2,18p' $SELF; exit 0 ;;
    *) print -r -- "teardown: unknown option $a" >&2; exit 2 ;;
  esac
done

die() { print -r -- "teardown: $*" >&2; exit 1; }
say() {
  print -r -- "teardown: $*"
  ( print -r -- "$(date '+%Y-%m-%dT%H:%M:%S') teardown: $*" >> $LOGS/teardown.log ) 2>/dev/null || true
}

[ "$LAYOUT" = bundle ] || die "this is the development checkout ($ROOT); remove
  /etc/sudoers.d/stage-mgr by hand instead — teardown.sh is for an installed app."

APP=$(cd $R/../../.. && pwd -P)          # <app>.app/Contents/Resources/wmship -> <app>.app
[[ $APP == *.app ]] || die "the tool is not inside a .app bundle: $APP"
GRANT=$APP/Contents/Resources/wmship/bin/asroot
[ "$GRANT" = "$ASROOT" ] || die "refusing: this copy would delete a rule for
  $GRANT
  while running from
  $ASROOT"

T=$(mktemp -d /tmp/stagepilot-teardown.XXXXXX) || die "no scratch directory"
trap '/bin/rm -rf '"$T" EXIT INT TERM

cat > $T/plan.sh <<PLAN
SRC=$T
SUDOERS=$SUDOERS
PLIST=$PLIST
LABEL=$PLIST_LABEL
GRANT=$GRANT
KEEP=$KEEP
D=$D
PLAN
cat > $T/run.sh <<'RUN'
#!/bin/zsh
set -u
SRC=${0:A:h}
. "$SRC/plan.sh"
out=$SRC/result
: > $out
say() { print -r -- "$*" >> $out; }

/bin/launchctl bootout system/$LABEL 2>/dev/null && say "daemon: booted out system/$LABEL" \
  || say "daemon: system/$LABEL was not loaded"
/bin/rm -f "$PLIST" && say "plist: removed $PLIST"

if [ -f "$SUDOERS" ]; then
  if grep -qF "$GRANT" "$SUDOERS"; then
    /bin/rm -f "$SUDOERS" && say "rule: removed $SUDOERS"
  else
    other=$(sed -n 's/.*NOPASSWD:[[:space:]]*//p' "$SUDOERS" | head -1)
    say "rule: LEFT IN PLACE — $SUDOERS grants $other, not this bundle"
  fi
else
  say "rule: $SUDOERS was not present"
fi

/usr/bin/pkill -x wmhb 2>/dev/null && say "helper: wmhb stopped"
/usr/bin/pkill -x wmobs 2>/dev/null && say "observer: wmobs stopped"
/usr/bin/pkill -x r21obs 2>/dev/null && say "observer: r21obs stopped"

if [ "$KEEP" = 1 ]; then
  say "state: kept $D (--keep-state)"
elif [ -e "$D" ]; then
  /bin/rm -rf "$D" && say "state: removed $D" || say "state: WARNING could not remove $D"
else
  say "state: $D was not present"
fi
exit 0
RUN
chmod 0755 $T/run.sh

ESCAPED=${T//\"/}
if [ "$(id -u)" = 0 ]; then
  /bin/zsh $T/run.sh
elif sudo -n "$ASROOT" -c true >/dev/null 2>&1; then
  sudo -n "$ASROOT" -c "/bin/zsh $ESCAPED/run.sh"
else
  /usr/bin/osascript -e "do shell script \"/bin/zsh $ESCAPED/run.sh\" with administrator privileges" >/dev/null 2>&1 \
    || say "WARNING: the privileged step did not run (canceled prompt?)"
fi

RES=$(cat $T/result 2>/dev/null)
if [ -z "$RES" ]; then
  say "FAILED: no result from the privileged step"
  exit 1
fi
print -r -- "$RES" | while IFS= read -r l; do say "$l"; done
if [ -e "$PLIST" ] || [ -e "$SUDOERS" ]; then
  say "INCOMPLETE: $PLIST or $SUDOERS still exists"
  exit 1
fi
say "removed. the window patch itself, if armed, is removed by '$R/wmship.sh stop'."
exit 0
