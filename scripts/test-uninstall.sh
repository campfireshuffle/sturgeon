#!/bin/bash
# test-uninstall.sh — prove that `brew uninstall --cask sturgeon` leaves nothing behind.
#
# NOT part of CI.  It installs into /Applications, writes /etc/sudoers.d/stage-pilot, loads a
# LaunchDaemon and ARMS the patch against the live WindowManager.  Run it only on a machine you
# are willing to disturb, from a checkout, as an administrator.
#
#   ./scripts/test-uninstall.sh                 # prints the plan and the exact commands; no changes
#   ./scripts/test-uninstall.sh --run          # package, install, arm, uninstall, assert
#   ./scripts/test-uninstall.sh --run --zap-only
#   ./scripts/test-uninstall.sh --run --negative   # also prove a broken cask is caught
#
# What --run does, in order:
#
#   1. refuses if anything is already installed or armed (a half-cleaned machine proves nothing)
#   2. SIGN_IDENTITY=- ./scripts/package.sh 0.0.0 1
#   3. brew install --cask ./dist/sturgeon.rb        (the file:// cask the package step generated)
#   4. sudo /Applications/Sturgeon.app/Contents/Resources/wmship/setup.sh
#   5. /Applications/Sturgeon.app/.../wmship.sh start   (ARMS the patch — the ordering trap)
#   6. asserts state.json names the running WindowManager and status says ARMED
#   7. brew uninstall --cask sturgeon               (NO manual stop: the cask must disarm)
#   8. asserts, with shell tests:
#        - /Applications/Sturgeon.app is gone
#        - com.stagemgr.wmshipd is not loaded
#        - /Library/LaunchDaemons/com.stagemgr.wmshipd.plist is gone
#        - /etc/sudoers.d/stage-pilot is gone
#        - /tmp/wmship is gone
#        - the brew output contains teardown's "patch: disarmed" (it restored before deleting)
#        - `install.py pristine` (run from the packaged copy, as root) says PRISTINE: yes
#   9. reinstalls, uninstalls with --zap, asserts ~/Library/Application Support/Sturgeon is gone
#
# The machine ends disarmed and pristine in both passes.  If any assertion fails the script stops
# with a non-zero exit and prints the recovery commands; it does not retry.
#
# --negative copies the cask with its uninstall stanza removed, runs the same install/arm/uninstall
# cycle, and PASSES only if the ordinary assertions would have failed (i.e. the test bites), then
# cleans up with the packaged teardown and re-verifies.  It needs the same privileges as --run.
#
# Requirements: Apple silicon, macOS 27+, SIP disabled, an admin account, Homebrew, Xcode command
# line tools, and a running WindowManager.  Nothing here needs a notarized or Developer ID build.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=0.0.0
BUILD=1
APP=/Applications/Sturgeon.app
PLIST=/Library/LaunchDaemons/com.stagemgr.wmshipd.plist
LABEL=com.stagemgr.wmshipd
SUDOERS=/etc/sudoers.d/stage-pilot
STATE=/tmp/wmship/state.json
SUPPORT="$HOME/Library/Application Support/Sturgeon"
DEV_TREE="$ROOT/dist/Sturgeon.app/Contents/Resources/wmship"

RUN=0
ZAP_ONLY=0
NEGATIVE=0
for a in "$@"; do
  case $a in
    --run) RUN=1 ;;
    --zap-only) ZAP_ONLY=1 ;;
    --negative) NEGATIVE=1 ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) printf 'test-uninstall: unknown option %s\n' "$a" >&2; exit 2 ;;
  esac
done

say() { printf 'test-uninstall: %s\n' "$*"; }
die() { printf 'test-uninstall: REFUSED: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------- preflight (no side effects)
[ "$(uname -s)" = Darwin ] || die "this is a macOS test"
[ "$(uname -m)" = arm64 ] || die "Sturgeon is arm64-only"
[ -z "${CI:-}" ] || die "not for CI: this test installs, arms and uninstalls on a live machine"
[ "$(id -u)" != 0 ] || die "run this as your normal admin account, not as root (it prompts through sudo)"
id -Gn | tr ' ' '\n' | grep -qx admin || die "the account must be an administrator"
command -v brew >/dev/null 2>&1 || die "Homebrew is required (brew install --cask)"
command -v swift >/dev/null 2>&1 || die "Xcode command line tools are required (swift)"
command -v codesign >/dev/null 2>&1 || die "codesign is required"

[ -x "$ROOT/scripts/package.sh" ] || die "run this from the Sturgeon checkout"
[ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ] || die "not a git checkout: $ROOT"

SIP=$(csrutil status 2>/dev/null || true)
case "$SIP" in
  *"status: disabled"*) : ;;
  *) die "SIP must be disabled for the arm step ($SIP)" ;;
esac

WM_PID=$(pgrep -x WindowManager 2>/dev/null | head -1)
[ -n "$WM_PID" ] || die "WindowManager is not running; the pristine assertion needs it"

for p in "$APP" "$PLIST" "$SUDOERS"; do
  if [ -e "$p" ]; then
    die "$p already exists — this machine is not clean.
  finish the previous uninstall first:
    sudo $APP/Contents/Resources/wmship/teardown.sh
  or, if the app is already gone:
    sudo launchctl bootout system/$LABEL 2>/dev/null; sudo rm -f $PLIST $SUDOERS"
  fi
done
if [ -e "$STATE" ]; then
  die "$STATE exists — something is armed. Run 'wmship.sh stop' and re-check before testing."
fi

if [ "$RUN" = 0 ]; then
  cat <<EOS
test-uninstall: plan only (nothing changed). Re-run with --run to execute it.

The script will, with administrator approval:
  SIGN_IDENTITY=- $ROOT/scripts/package.sh $VERSION $BUILD
  brew install --cask $ROOT/dist/sturgeon.rb
  sudo $APP/Contents/Resources/wmship/setup.sh
  $APP/Contents/Resources/wmship/wmship.sh start     # arms the live WindowManager
  brew uninstall --cask sturgeon                     # must disarm before deleting
  # assertions: app/plist/sudoers/daemon/state gone, PRISTINE: yes
  # then a second install + 'brew uninstall --zap --cask sturgeon' for the zap assertions

This ARMS the patch on your working machine. Do not run it while another test is armed.
EOS
  exit 2
fi

# ---------------------------------------------------------------- assertions
FAILED=0
CHECKS=0
ok()   { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$*"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$*"; }
check_absent() {  # check_absent <path> <description>
  if [ ! -e "$1" ]; then ok "$2 is absent ($1)"; else bad "$2 still exists ($1)"; fi
}
check_absent_root() {
  if sudo test ! -e "$1" 2>/dev/null; then
    ok "$2 is absent ($1)"
  else
    bad "$2 still exists ($1)"
  fi
}

# Every expectation is a real shell test.  `strict` controls whether a failure is fatal here or
# merely recorded; the --negative pass inverts the outcome so a missing uninstall stanza is caught.
assert_uninstalled() {
  local strict=${1:-1}
  local before=$FAILED
  check_absent "$APP" "the application"
  if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
    bad "LaunchDaemon system/$LABEL is still loaded"
  else
    ok "LaunchDaemon system/$LABEL is not loaded"
  fi
  check_absent_root "$PLIST" "the LaunchDaemon plist"
  check_absent_root "$SUDOERS" "the sudoers rule"
  check_absent_root /tmp/wmship "/tmp/wmship"

  if ! pgrep -x wmhb >/dev/null 2>&1; then
    ok "no wmhb helper process"
  else
    bad "wmhb is still running"
  fi
  if ! pgrep -f wmshipd.py >/dev/null 2>&1; then
    ok "no wmshipd.py daemon process"
  else
    bad "wmshipd.py is still running"
  fi

  # The six sites: compare live bytes with the on-disk WindowManager image using the packaged
  # engine that survived brew's app removal (dist/ is ours, not Homebrew's).
  if [ -x "$DEV_TREE/wmship/install.py" ]; then
    local pristine
    pristine=$(sudo /usr/bin/python3 "$DEV_TREE/wmship/install.py" pristine 2>&1)
    if printf '%s\n' "$pristine" | grep -q '^PRISTINE: yes'; then
      ok "all six WindowManager sites are byte-exact with the on-disk image"
    else
      bad "WindowManager sites are NOT pristine:"
      printf '%s\n' "$pristine" | tail -8 | sed 's/^/       /'
    fi
  else
    bad "cannot check pristine: $DEV_TREE/wmship/install.py is missing"
  fi

  local failed_here=$((FAILED - before))
  if [ "$strict" = 1 ] && [ "$failed_here" != 0 ]; then
    printf '\n%d assertion(s) failed. Recovery:\n' "$failed_here" >&2
    printf '  sudo %s/wmship/wmship.sh stop    # only if the tree still exists\n' "$DEV_TREE" >&2
    printf '  sudo launchctl bootout system/%s 2>/dev/null; sudo rm -f %s %s\n' "$LABEL" "$PLIST" "$SUDOERS" >&2
    return 1
  fi
  return 0
}

cleanup_after_negative() {
  say "negative pass: cleaning up the leftover install"
  if [ -x "$DEV_TREE/wmship/install.py" ]; then
    sudo /usr/bin/python3 "$DEV_TREE/wmship/install.py" uninstall >/dev/null 2>&1 || true
    sudo /usr/bin/python3 "$DEV_TREE/wmship/install.py" pristine >/dev/null 2>&1 || true
  fi
  sudo launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  sudo rm -f "$PLIST" "$SUDOERS"
  sudo rm -rf /tmp/wmship
  sudo pkill -x wmhb 2>/dev/null || true
  sudo pkill -f wmshipd.py 2>/dev/null || true
}

install_and_arm() {
  say "packaging (ad-hoc, $VERSION/$BUILD)"
  SIGN_IDENTITY=- "$ROOT/scripts/package.sh" "$VERSION" "$BUILD" >/dev/null \
    || die "package.sh failed"
  [ -d "$ROOT/dist/Sturgeon.app" ] || die "package.sh produced no dist/Sturgeon.app"
  [ -f "$ROOT/dist/sturgeon.rb" ] || die "package.sh produced no dist/sturgeon.rb"

  say "brew install --cask $ROOT/dist/sturgeon.rb"
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$ROOT/dist/sturgeon.rb" \
    || die "brew install failed"
  [ -d "$APP" ] || die "brew install left no $APP"

  say "setup (one administrator approval)"
  sudo "$APP/Contents/Resources/wmship/setup.sh" || die "setup.sh failed"
  sudo -n "$APP/Contents/Resources/wmship/bin/asroot" probe 2>/dev/null \
    || die "the NOPASSWD rule does not work after setup"

  say "arming the patch (wmship.sh start)"
  "$APP/Contents/Resources/wmship/wmship.sh" start || die "wmship.sh start failed"

  # The trap only exists if the payload really was armed.
  [ -f "$STATE" ] || die "start did not write $STATE — the ordering assertion would be vacuous"
  local pid
  pid=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$STATE")
  [ "$pid" = "$WM_PID" ] || die "state.json names pid $pid, WindowManager is $WM_PID — not armed"
  "$APP/Contents/Resources/wmship/wmship.sh" status 2>/dev/null | grep -q '^state: *ARMED' \
    || die "status does not report ARMED after start"
  ok "the patch is armed against WindowManager pid $WM_PID"
}

# ---------------------------------------------------------------- pass 1: plain uninstall
if [ "$ZAP_ONLY" = 0 ]; then
  install_and_arm

  say "brew uninstall --cask sturgeon (no manual stop: the cask must disarm first)"
  BREW_LOG=$(mktemp "${TMPDIR:-/tmp}/sturgeon-uninstall.XXXXXX") || die "no scratch file"
  HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --cask sturgeon 2>&1 | tee "$BREW_LOG"
  BREW_RC=${PIPESTATUS[0]}
  [ "$BREW_RC" = 0 ] || bad "brew uninstall exited $BREW_RC"
  if grep -q 'patch: disarmed' "$BREW_LOG"; then
    ok "teardown disarmed the patch before removing the helper"
    disarm_line=$(grep -n 'patch: disarmed' "$BREW_LOG" | head -1 | cut -d: -f1)
    stop_line=$(grep -n 'daemon: booted out' "$BREW_LOG" | head -1 | cut -d: -f1)
    if [ -n "$disarm_line" ] && [ -n "$stop_line" ] && [ "$disarm_line" -lt "$stop_line" ]; then
      ok "the restore is reported before the daemon stop (line $disarm_line < $stop_line)"
    else
      bad "the output does not show the restore before the daemon stop"
    fi
  else
    bad "teardown did not report 'patch: disarmed' (ordering trap)"
  fi
  assert_uninstalled 1 || exit 1
  rm -f "$BREW_LOG"
fi

# ---------------------------------------------------------------- pass 2: --zap
say "second install, then brew uninstall --zap --cask sturgeon"
install_and_arm
ZAP_LOG=$(mktemp "${TMPDIR:-/tmp}/sturgeon-zap.XXXXXX") || die "no scratch file"
HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --zap --cask sturgeon 2>&1 | tee "$ZAP_LOG"
ZAP_RC=${PIPESTATUS[0]}
[ "$ZAP_RC" = 0 ] || bad "brew uninstall --zap exited $ZAP_RC"
grep -q 'patch: disarmed' "$ZAP_LOG" && ok "zap pass disarmed first" || bad "zap pass did not disarm"
assert_uninstalled 1 || exit 1
check_absent "$SUPPORT" "the Application Support state (--zap)" || true
rm -f "$ZAP_LOG"

# ---------------------------------------------------------------- optional negative proof
if [ "$NEGATIVE" = 1 ]; then
  say "negative pass: a cask whose uninstall stanza was removed must be caught"
  NEGDIR=$(mktemp -d "${TMPDIR:-/tmp}/sturgeon-broken-cask.XXXXXX") || die "no scratch directory"
  # keep the token so brew uninstalls this install; drop the uninstall block entirely
  /usr/bin/python3 - "$ROOT/dist/sturgeon.rb" "$NEGDIR/sturgeon.rb" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
text, n = re.subn(r"\n  uninstall script: \{.*?\n  \}\n", "\n", text, flags=re.S)
if n != 1:
    raise SystemExit("could not remove exactly one uninstall stanza (removed %d)" % n)
open(dst, "w").write(text)
PY
  [ -f "$NEGDIR/sturgeon.rb" ] || die "could not build the broken cask"

  say "installing and arming the broken cask"
  SIGN_IDENTITY=- "$ROOT/scripts/package.sh" "$VERSION" "$BUILD" >/dev/null || die "package failed"
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$NEGDIR/sturgeon.rb" || die "broken cask install failed"
  sudo "$APP/Contents/Resources/wmship/setup.sh" || die "setup failed"
  "$APP/Contents/Resources/wmship/wmship.sh" start || die "start failed"

  say "brew uninstall --cask sturgeon with the broken cask (expected to leave everything)"
  HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --cask sturgeon 2>&1 | tail -20 || true

  BEFORE_NEG=$FAILED
  # Run the assertions but ignore their verdict: leftovers are the expected result.
  assert_uninstalled 0
  LEFTOVERS=$((FAILED - BEFORE_NEG))
  FAILED=$BEFORE_NEG                     # the negative pass does not count against the result
  if [ "$LEFTOVERS" -gt 0 ]; then
    ok "a cask without the uninstall stanza is caught ($LEFTOVERS failed assertions)"
  else
    bad "the assertions did NOT notice a missing uninstall stanza — the test is vacuous"
  fi
  cleanup_after_negative
  assert_uninstalled 1 || exit 1
  rm -rf "$NEGDIR"
fi

# ---------------------------------------------------------------- result
if [ "$FAILED" = 0 ]; then
  printf '\ntest-uninstall: %d checks passed. The machine is disarmed and pristine.\n' "$CHECKS"
  exit 0
fi
printf '\ntest-uninstall: %d of %d checks failed.\n' "$FAILED" "$CHECKS" >&2
exit 1
