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
# What --run does, in order.  Every `brew uninstall` is bounded (STURGEON_UNINSTALL_TIMEOUT,
# default 120s): the 1.0.1 bug was an uninstall that waited on an administrator dialog forever, so
# a hung run has to FAIL here, not sit in the harness.
#
#   pass 1 — ARMED (issue #21): install, setup, `wmship.sh start`, then `brew uninstall` with no
#            manual stop.  Asserts the restore is reported BEFORE the daemon stop, and that
#            WindowManager is byte-exact pristine afterwards.
#   pass 2 — DISARMED (issue #44): install, setup, do not arm.  The uninstall must complete
#            without a password prompt and remove everything.
#   pass 3 — MISSING BUNDLE (issue #44): install, setup, do not arm, then move Sturgeon.app away
#            the way a Trash-drag does.  `brew uninstall` must still exit 0 and remove the cask
#            RECORD (`brew list --cask`), print the exact privileged cleanup, and leave a machine
#            that is clean once that cleanup is run.
#   pass 4 — --zap (issue #14): install, setup, arm, plant ~/Library/Application Support/Sturgeon,
#            then `brew uninstall --zap`.  Asserts /tmp/wmship and the Application Support
#            directory are gone as well.
#   pass 5 — --negative (optional): a cask whose uninstall stanza was removed must be caught.
#
# Assertions, all shell tests: /Applications/Sturgeon.app gone, launchd job not loaded, plist gone,
# sudoers rule gone, /tmp/wmship gone, no wmhb/wmshipd.py process, `install.py pristine` says
# PRISTINE: yes.  The machine ends disarmed and pristine in every pass.  If any assertion fails the
# script stops with a non-zero exit and prints the recovery commands; it does not retry.
#
# --negative copies the cask with its uninstall stanza removed, runs the same install/arm/uninstall
# cycle, and PASSES only if the ordinary assertions would have failed (i.e. the test bites), then
# cleans up with the packaged teardown and re-verifies.
#
# The packaged cask is staged into a throw-away local tap (sturgeon-proof/local): Homebrew 5 and
# later refuse `brew install --cask ./dist/sturgeon.rb` and refuse a tap that has not been trusted,
# so the release tap cannot be exercised by a local file path any more.
#
# STURGEON_SUDO names the root command (default `sudo`).  It exists so an unattended proof can use
# a pre-armed root wrapper instead of a password prompt; it must accept the same argv as sudo.
# STURGEON_VERSION / STURGEON_BUILD override the 0.0.0/1 default used for the packaged artifact.
#
# Requirements: Apple silicon, macOS 27+, SIP disabled, an admin account, Homebrew, Xcode command
# line tools, perl (for the alarm), and a running WindowManager.  Nothing here needs a notarized
# or Developer ID build.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${STURGEON_VERSION:-0.0.0}
BUILD=${STURGEON_BUILD:-1}
APP=/Applications/Sturgeon.app
PLIST=/Library/LaunchDaemons/com.stagemgr.wmshipd.plist
LABEL=com.stagemgr.wmshipd
SUDOERS=/etc/sudoers.d/stage-pilot
STATE=/tmp/wmship/state.json
SUPPORT="$HOME/Library/Application Support/Sturgeon"
DEV_TREE="$ROOT/dist/Sturgeon.app/Contents/Resources/wmship"
SUDO=${STURGEON_SUDO:-sudo}
TIMEOUT=${STURGEON_UNINSTALL_TIMEOUT:-120}
# Homebrew 5 and later refuse `brew install --cask ./path/to/x.rb` ("requires casks to be in a tap")
# and refuse an untrusted tap, so the freshly packaged cask is staged into a throw-away local tap.
TAP=sturgeon-proof/local
TAP_DIR="$(brew --repository)/Library/Taps/sturgeon-proof/homebrew-local"
export HOMEBREW_NO_AUTO_UPDATE=1

RUN=0
ZAP_ONLY=0
NEGATIVE=0
for a in "$@"; do
  case $a in
    --run) RUN=1 ;;
    --zap-only) ZAP_ONLY=1 ;;
    --negative) NEGATIVE=1 ;;
    -h|--help) sed -n '2,49p' "$0"; exit 0 ;;
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
[ -x /usr/bin/perl ] || die "/usr/bin/perl is required (it bounds each brew uninstall)"

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
if brew list --cask 2>/dev/null | grep -qx sturgeon; then
  die "the cask is still installed; 'brew uninstall --cask sturgeon' first"
fi

if [ "$RUN" = 0 ]; then
  EXTRA=""
  [ "$NEGATIVE" = 1 ] && EXTRA="  pass 5 --NEGATIVE     a cask without the uninstall stanza must be caught"
  cat <<EOS
test-uninstall: plan only (nothing changed). Re-run with --run to execute it.

Each pass starts from a clean machine and asserts with shell tests that the app, the launchd job,
the plist, the sudoers rule, /tmp/wmship and every wmhb/wmshipd.py process are gone and that all
six WindowManager sites are byte-exact pristine.  Every brew uninstall is bounded to ${TIMEOUT}s.

  pass 1 ARMED          package, install, setup, wmship.sh start, brew uninstall
  pass 2 DISARMED       package, install, setup, (no start), brew uninstall
  pass 3 MISSING BUNDLE package, install, setup, move the app away, brew uninstall
  pass 4 --ZAP          package, install, setup, start, brew uninstall --zap
${EXTRA}
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
  if $SUDO test ! -e "$1" 2>/dev/null; then
    ok "$2 is absent ($1)"
  else
    bad "$2 still exists ($1)"
  fi
}

assert_pristine() {   # assert_pristine <strict>
  local strict=${1:-1}
  local before=$FAILED
  if [ -x "$DEV_TREE/install.py" ]; then
    local pristine
    pristine=$($SUDO /usr/bin/python3 "$DEV_TREE/install.py" pristine 2>&1)
    if printf '%s\n' "$pristine" | grep -q '^PRISTINE: yes'; then
      ok "all six WindowManager sites are byte-exact with the on-disk image"
    else
      bad "WindowManager sites are NOT pristine:"
      printf '%s\n' "$pristine" | tail -8 | sed 's/^/       /'
    fi
  else
    bad "cannot check pristine: $DEV_TREE/wmship/install.py is missing"
  fi
  if [ "$strict" = 1 ] && [ "$FAILED" != "$before" ]; then return 1; fi
  return 0
}

assert_uninstalled() {   # assert_uninstalled <strict>
  local strict=${1:-1}
  local before=$FAILED
  local i
  check_absent "$APP" "the application"
  if $SUDO launchctl print "system/$LABEL" >/dev/null 2>&1; then
    bad "LaunchDaemon system/$LABEL is still loaded"
  else
    ok "LaunchDaemon system/$LABEL is not loaded"
  fi
  check_absent_root "$PLIST" "the LaunchDaemon plist"
  check_absent_root "$SUDOERS" "the sudoers rule"
  check_absent_root /tmp/wmship "/tmp/wmship"
  if brew list --cask 2>/dev/null | grep -qx sturgeon; then
    bad "the cask record is still in 'brew list --cask'"
  else
    ok "the cask record is gone (brew list --cask)"
  fi

  for i in $(seq 1 20); do
    pgrep -x wmhb >/dev/null 2>&1 || pgrep -f wmshipd.py >/dev/null 2>&1 || break
    sleep 0.25
  done
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
  assert_pristine 0

  local failed_here=$((FAILED - before))
  if [ "$strict" = 1 ] && [ "$failed_here" != 0 ]; then
    printf '\n%d assertion(s) failed. Recovery:\n' "$failed_here" >&2
    printf '  sudo %s/wmship.sh stop    # only if the tree still exists\n' "$DEV_TREE" >&2
    printf '  sudo launchctl bootout system/%s 2>/dev/null; sudo rm -f %s %s\n' "$LABEL" "$PLIST" "$SUDOERS" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- helpers
# `brew uninstall … --cask sturgeon`, bounded by an alarm so a prompt that never gets an answer
# fails the test instead of hanging it (#44).  Prints the output and sets LAST_RC.
LAST_RC=0
brew_uninstall() {   # brew_uninstall <logfile> [extra brew args…]
  local log=$1; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$TIMEOUT" \
    brew uninstall "$@" --cask sturgeon 2>&1 | tee "$log"
  LAST_RC=${PIPESTATUS[0]}
  case "$LAST_RC" in
    142|143) bad "brew uninstall did not finish within ${TIMEOUT}s — it is waiting on a prompt (#44)" ;;
  esac
  return 0
}

# The privileged leftovers a missing bundle cannot clean itself.  Only used by pass 3, after the
# test has asserted that the cask did NOT silently claim to have removed them.
clean_leftovers() {
  $SUDO /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  $SUDO /bin/rm -f "$PLIST" "$SUDOERS"
  $SUDO /bin/rm -rf /tmp/wmship
  $SUDO /usr/bin/pkill -x wmhb 2>/dev/null || true
  $SUDO /usr/bin/pkill -f wmshipd.py 2>/dev/null || true
}

cleanup_after_negative() {
  say "negative pass: cleaning up the leftover install"
  if [ -x "$DEV_TREE/install.py" ]; then
    $SUDO /usr/bin/python3 "$DEV_TREE/install.py" uninstall >/dev/null 2>&1 || true
    $SUDO /usr/bin/python3 "$DEV_TREE/install.py" pristine >/dev/null 2>&1 || true
  fi
  clean_leftovers
}

prepare() {
  say "packaging (ad-hoc, $VERSION/$BUILD)"
  SIGN_IDENTITY=- "$ROOT/scripts/package.sh" "$VERSION" "$BUILD" >/dev/null \
    || die "package.sh failed"
  [ -d "$ROOT/dist/Sturgeon.app" ] || die "package.sh produced no dist/Sturgeon.app"
  [ -f "$ROOT/dist/sturgeon.rb" ] || die "package.sh produced no dist/sturgeon.rb"

  say "staging the cask in the local tap $TAP"
  mkdir -p "$TAP_DIR/Casks" || die "cannot create $TAP_DIR"
  cp "$ROOT/dist/sturgeon.rb" "$TAP_DIR/Casks/sturgeon.rb" || die "cannot stage the cask"
  brew trust --cask "$TAP/sturgeon" >/dev/null 2>&1 || die "could not trust the local tap"

  say "brew install --cask $TAP/sturgeon"
  brew install --cask "$TAP/sturgeon" || die "brew install failed"
  [ -d "$APP" ] || die "brew install left no $APP"
}

install_only() {
  prepare
  say "setup (one administrator approval)"
  $SUDO "$APP/Contents/Resources/wmship/setup.sh" || die "setup.sh failed"
  $SUDO "$APP/Contents/Resources/wmship/bin/asroot" probe 2>/dev/null \
    || die "the NOPASSWD rule does not work after setup"
}

install_and_arm() {
  install_only
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

# ---------------------------------------------------------------- pass 1: armed uninstall
if [ "$ZAP_ONLY" = 0 ]; then
  say "pass 1/4: ARMED uninstall (#21)"
  install_and_arm

  say "brew uninstall --cask sturgeon (no manual stop: the cask must disarm first)"
  BREW_LOG=$(mktemp "${TMPDIR:-/tmp}/sturgeon-uninstall.XXXXXX") || die "no scratch file"
  brew_uninstall "$BREW_LOG"
  [ "$LAST_RC" = 0 ] || bad "brew uninstall exited $LAST_RC"
  if grep -q 'patch: disarmed' "$BREW_LOG"; then
    ok "teardown disarmed the patch before removing the helper"
    disarm_line=$(grep -n 'patch: disarmed' "$BREW_LOG" | head -1 | cut -d: -f1)
    boot_line=$(grep -n 'daemon: booted out' "$BREW_LOG" | head -1 | cut -d: -f1)
    verify_line=$(grep -n 'verified pristine again after the daemon stop' "$BREW_LOG" | head -1 | cut -d: -f1)
    rule_line=$(grep -n 'rule: removed' "$BREW_LOG" | head -1 | cut -d: -f1)
    if [ -n "$disarm_line" ] && [ -n "$boot_line" ] && [ "$disarm_line" -lt "$boot_line" ]; then
      ok "the restore is reported before the daemon stop (line $disarm_line < $boot_line)"
    else
      bad "the output does not show the restore before the daemon stop"
    fi
    if [ -n "$verify_line" ] && [ -n "$rule_line" ] && [ "$verify_line" -lt "$rule_line" ]; then
      ok "the second pristine check is reported before the rule is deleted (line $verify_line < $rule_line)"
    else
      bad "the output does not show the second pristine check before the rule removal"
    fi
  else
    bad "teardown did not report 'patch: disarmed' (ordering trap)"
  fi
  assert_uninstalled 1 || exit 1
  rm -f "$BREW_LOG"

  # ---------------------------------------------------------------- pass 2: disarmed
  say "pass 2/4: DISARMED uninstall (#44)"
  install_only
  [ ! -e "$STATE" ] || die "something armed itself; pass 2 would not exercise the disarmed path"
  BREW_LOG=$(mktemp "${TMPDIR:-/tmp}/sturgeon-plain.XXXXXX") || die "no scratch file"
  brew_uninstall "$BREW_LOG"
  [ "$LAST_RC" = 0 ] || bad "disarmed brew uninstall exited $LAST_RC"
  grep -q 'nothing was armed' "$BREW_LOG" \
    && ok "teardown reported there was nothing armed (no restore needed)" \
    || bad "teardown did not report a disarmed state"
  grep -q 'Running uninstall script /bin/zsh' "$BREW_LOG" \
    && ok "homebrew ran the always-present guard, not a bundle path" \
    || bad "homebrew did not run the /bin/zsh guard"
  assert_uninstalled 1 || exit 1
  rm -f "$BREW_LOG"

  # ---------------------------------------------------------------- pass 3: missing bundle
  say "pass 3/4: MISSING BUNDLE uninstall (#44)"
  install_only
  PARK=$(mktemp -d "${TMPDIR:-/tmp}/sturgeon-parked.XXXXXX") || die "no scratch directory"
  mv "$APP" "$PARK/Sturgeon.app" || die "could not move the app away"
  ok "the app bundle is gone the way a Trash-drag removes it ($PARK)"
  BREW_LOG=$(mktemp "${TMPDIR:-/tmp}/sturgeon-missing.XXXXXX") || die "no scratch file"
  brew_uninstall "$BREW_LOG"
  [ "$LAST_RC" = 0 ] || bad "missing-bundle brew uninstall exited $LAST_RC (it must complete)"
  if brew list --cask 2>/dev/null | grep -qx sturgeon; then
    bad "the cask record survived a missing app bundle"
  else
    ok "the cask record is gone after a missing-bundle uninstall"
  fi
  check_absent "$APP" "the application"
  grep -q 'the app bundle was removed before the cask' "$BREW_LOG" \
    && ok "the guard explained the missing bundle instead of failing" \
    || bad "no explanation for the missing bundle"
  grep -q 'sudo /bin/rm -f /Library/LaunchDaemons/com.stagemgr.wmshipd.plist' "$BREW_LOG" \
    && ok "the guard printed the exact privileged cleanup" \
    || bad "the guard did not print the privileged cleanup"
  # The leftovers are expected here — no bundle means no helper and no way to be root.  Clean them
  # the way the guard told the user to, then assert the machine is as clean as pass 1 leaves it.
  say "finishing the cleanup the guard printed (as root)"
  clean_leftovers
  rm -rf "$PARK"
  assert_uninstalled 1 || exit 1
  rm -f "$BREW_LOG"
fi

# ---------------------------------------------------------------- pass 4: --zap
say "pass 4/4: --zap uninstall (#14)"
install_and_arm
mkdir -p "$SUPPORT" && printf 'marker\n' > "$SUPPORT/test-uninstall-marker" \
  || die "could not plant $SUPPORT"
ok "planted ~/Library/Application Support/Sturgeon (the zap target)"
ZAP_LOG=$(mktemp "${TMPDIR:-/tmp}/sturgeon-zap.XXXXXX") || die "no scratch file"
brew_uninstall "$ZAP_LOG" --zap
[ "$LAST_RC" = 0 ] || bad "brew uninstall --zap exited $LAST_RC"
grep -q 'patch: disarmed' "$ZAP_LOG" && ok "zap pass disarmed first" || bad "zap pass did not disarm"
assert_uninstalled 1 || exit 1
check_absent "$SUPPORT" "the Application Support state (--zap)"
check_absent_root /tmp/wmship "/tmp/wmship (--zap)"
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
text, n = re.subn(r"\n  uninstall script: \{.*?\n            \}\n", "\n", text, flags=re.S)
if n != 1:
    raise SystemExit("could not remove exactly one uninstall stanza (removed %d)" % n)
open(dst, "w").write(text)
PY
  [ -f "$NEGDIR/sturgeon.rb" ] || die "could not build the broken cask"

  say "installing and arming the broken cask"
  cp "$NEGDIR/sturgeon.rb" "$TAP_DIR/Casks/sturgeon.rb" || die "cannot stage the broken cask"
  brew install --cask "$TAP/sturgeon" || die "broken cask install failed"
  $SUDO "$APP/Contents/Resources/wmship/setup.sh" || die "setup failed"
  "$APP/Contents/Resources/wmship/wmship.sh" start || die "start failed"

  say "brew uninstall --cask sturgeon with the broken cask (expected to leave everything)"
  NEG_LOG=$(mktemp "${TMPDIR:-/tmp}/sturgeon-negative.XXXXXX") || die "no scratch file"
  brew_uninstall "$NEG_LOG"

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
  rm -f "$NEG_LOG"
  cleanup_after_negative
  assert_uninstalled 1 || exit 1
  cp "$ROOT/dist/sturgeon.rb" "$TAP_DIR/Casks/sturgeon.rb"   # put the good cask back
  rm -rf "$NEGDIR"
fi

# ---------------------------------------------------------------- result
if [ "$FAILED" = 0 ]; then
  printf '\ntest-uninstall: %d checks passed. The machine is disarmed and pristine.\n' "$CHECKS"
  exit 0
fi
printf '\ntest-uninstall: %d of %d checks failed.\n' "$FAILED" "$CHECKS" >&2
exit 1
