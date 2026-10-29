#!/bin/zsh
# teardown.sh — remove the two privileged pieces of an installed Sturgeon (idempotent).
#
#   Sturgeon.app/Contents/Resources/wmship/teardown.sh [--keep-state]
#
# Order matters, and this is the whole point of the script (issue #21):
#
#   1. if /tmp/wmship/state.json exists, restore the six patch sites with install.py and verify
#      them byte-exact with `install.py pristine` — BEFORE the helper that knows how to restore
#      them is deleted.  A WindowManager pid mismatch is a clean "already restored" exit 0; a
#      restore that cannot be verified is reported loudly and the removal still continues.
#   2. boot the LaunchDaemon out and stop the helper and observers.
#   3. verify pristine again: the daemon re-applies the patch periodically, so a site could have
#      been rewritten between step 1 and the bootout.
#   4. delete the plist and /etc/sudoers.d/stage-pilot — but ONLY if the rule grants this
#      bundle's bin/asroot.
#   5. delete /tmp/wmship (root-owned runtime state) unless --keep-state.
#
# If nothing privileged exists (no plist, no rule, nothing armed) it removes only the runtime
# directory it can remove itself and exits 0, without asking for a password to do nothing.
#
# The privileged half is the `teardown` verb of the bundled bin/asroot, a compiled dispatcher that
# accepts a fixed verb list and never runs a shell command.  Elevation is: already root, then the
# tool's own NOPASSWD helper (so `brew uninstall` needs no password while the app is still
# allowed).  There is deliberately NO third step: an `osascript … with administrator privileges`
# dialog cannot be answered in a non-interactive `brew uninstall` and blocked one for 30 minutes
# (issue #44), so with no root and no working rule this exits 3, changes nothing and prints the
# one command to run.  Nothing is stored.  It refuses when the rule it would delete names a
# different helper than the one running.
#
# Exit codes: 0 removed (or nothing was installed), 1 the privileged step ran but is incomplete
# or the restore could not be verified, 2 usage, 3 no root and no NOPASSWD rule — nothing changed.
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
    -h|--help) sed -n '2,34p' $SELF; exit 0 ;;
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

# ---------------------------------------------------------------- is there anything privileged?
# Deleting a file in /Library or /etc needs root, and so does restoring a patch that only root
# could have applied.  If none of that is present (a plain `brew install`, or a previous
# `wmship.sh stop`), do not demand a password to remove nothing.
WORK=0
[ -e "$PLIST" ] && WORK=1
[ -e "$SUDOERS" ] && WORK=1
[ -e "$D/state.json" ] && WORK=1
if [ "$WORK" = 0 ]; then
  if [ -e "$D" ]; then
    # Only remove a runtime directory this user owns.  Once the daemon has run, /tmp/wmship is
    # root-owned (and 0777, so a plain `rm -rf` would happily unlink root's files): say what to run
    # instead of guessing.
    if [ -O "$D" ] && rm -rf "$D" 2>/dev/null && [ ! -e "$D" ]; then
      say "removed the runtime directory $D"
    else
      say "$D is root-owned, so it is left in place; remove it with:"
      print -r -- "  sudo /bin/rm -rf $D"
    fi
  fi
  say "nothing privileged to remove: no $PLIST, no $SUDOERS, nothing armed — done"
  exit 0
fi

# ---------------------------------------------------------------- the privileged half
RC=0
if [ "$(id -u)" = 0 ]; then
  RES=$("$ASROOT" teardown "${ARGS[@]}" 2>&1) || RC=$?
elif sudo -n "$ASROOT" probe >/dev/null 2>&1; then
  RES=$(sudo -n "$ASROOT" teardown "${ARGS[@]}" 2>&1) || RC=$?
else
  # No root and no working NOPASSWD rule.  This used to raise an `osascript` administrator dialog,
  # which is a GUI prompt: under `brew uninstall` with nobody at the keyboard it blocked forever
  # (30 minutes, observed on 1.0.1 — issue #44).  Change nothing, say exactly what to run, and
  # fail fast so the cask keeps the app instead of deleting the only copy of the restore tool.
  say "REFUSED: this needs root, and no NOPASSWD rule is installed for"
  print -r -- "  $ASROOT"
  say "Nothing was changed and no patch was touched.  Run this, then repeat the uninstall:"
  print -r -- "  sudo \"$SELF\""
  exit 3
fi

if [ -z "$RES" ]; then
  say "FAILED: the privileged step produced no output"
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
case "$RES" in
  *"nothing was armed"*) say "removed. nothing was armed — there was no patch to restore." ;;
  *) say "removed. the patch was disarmed above, before the helper that can restore it was deleted." ;;
esac
exit 0
