#!/bin/zsh
# teardown.sh — remove the two privileged pieces of an installed Sturgeon (idempotent).
#
#   Sturgeon.app/Contents/Resources/wmship/teardown.sh [--keep-state]
#
# Order matters, and this is the whole point of the script:
#
#   0. if /tmp/wmship/state.json exists, restore the six patch sites with install.py and verify
#      them byte-exact with `install.py pristine` — BEFORE the helper that knows how to restore
#      them is deleted.  A WindowManager pid mismatch is a clean "already restored" exit 0; a
#      restore that cannot be verified is reported loudly and the removal still continues.
#   1. boot out and delete /Library/LaunchDaemons/com.stagemgr.wmshipd.plist
#      (and the helper it spawned — the patch itself was removed in step 0)
#   2. delete /etc/sudoers.d/stage-pilot — but ONLY if it grants this bundle's bin/asroot
#   3. delete /tmp/wmship (root-owned runtime state) unless --keep-state
#
# The privileged half is the `teardown` verb of the bundled bin/asroot, a compiled dispatcher that
# accepts a fixed verb list and never runs a shell command.  Elevation order: already root, then
# the tool's own NOPASSWD helper (so `brew uninstall` needs no password while the app is still
# allowed), then one administrator prompt.  Nothing is stored.  It refuses when the rule it would
# delete names a different helper than the one running.
#
# The user caches in ~/Library/Application Support/Sturgeon are NOT touched: an uninstall without
# `zap` keeps them, exactly like the cask's `zap` stanza describes.
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
    -h|--help) sed -n '2,24p' $SELF; exit 0 ;;
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
[ -x "$ASROOT" ] || die "$ASROOT is missing"
"$ASROOT" --verbs >/dev/null 2>&1 || die "$ASROOT is not the verb-limited helper"

ARGS=()
[ "$KEEP" = 1 ] && ARGS+=(--keep-state)

# ---------------------------------------------------------------- the privileged half
RC=0
if [ "$(id -u)" = 0 ]; then
  RES=$("$ASROOT" teardown "${ARGS[@]}" 2>&1) || RC=$?
elif sudo -n "$ASROOT" probe >/dev/null 2>&1; then
  RES=$(sudo -n "$ASROOT" teardown "${ARGS[@]}" 2>&1) || RC=$?
else
  # Repair path: the NOPASSWD rule is gone or grants another copy.  One administrator prompt,
  # running the same fixed verb as root.  No command is built from user input.
  CMD=$(printf '%q ' "$ASROOT" teardown "${ARGS[@]}")
  RES=$(/usr/bin/osascript -e "do shell script \"$CMD\" with administrator privileges" 2>&1) || RC=$?
fi

if [ -z "$RES" ]; then
  say "FAILED: the privileged step produced no output (canceled password prompt?)"
  exit 1
fi
print -r -- "$RES" | while IFS= read -r l; do say "$l"; done

if [ -e "$PLIST" ] || [ -e "$SUDOERS" ]; then
  say "INCOMPLETE: $PLIST or $SUDOERS still exists"
  exit 1
fi
case "$RES" in
  *"PATCH: UNVERIFIED"*)
    say "FAILED: the privileged files are gone, but the WindowManager restore could not be verified."
    say "        Reinstall the app and run '$R/wmship.sh stop', or 'wmship.sh pristine' to check."
    exit 1 ;;
esac
if [ "$RC" != 0 ]; then
  say "INCOMPLETE: the privileged step exited $RC"
  exit 1
fi
say "removed. the patch was disarmed above, before the helper that can restore it was deleted."
exit 0
