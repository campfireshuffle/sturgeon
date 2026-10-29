#!/bin/bash
# selftest.sh — assert the things about a built app bundle that need no root and no WindowManager.
#
#   ./scripts/selftest.sh [path/to/Sturgeon.app]
#
# The default target is the RELEASE bundle, art/Sturgeon.app: that is the artifact the cask
# downloads and the notary service inspects.  A dev build from scripts/build-app.sh has the same
# contents now (island.o is never copied in), but art/ is the contract, so the release bundle is
# what CI checks.  Pass dist/Sturgeon.app explicitly to check a pre-package bundle.
#
# Exit 0 when every assertion holds.  Nothing here creates a file in the bundle, starts a process
# that patches anything, or calls sudo with a successful rule: `wmship.sh doctor` is expected to
# *refuse* without root, and a crash (exit > 1, or a signal) is a failure.  `wmlayout.py shell`
# does create the writable state directory it would create for any user command
# (~/Library/Application Support/Sturgeon); that is the tool's normal layout resolution, not a
# modification of the bundle.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
APP=${1:-$ROOT/art/Sturgeon.app}

FAILED=0
CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

die() { printf 'selftest: %s\n' "$*" >&2; exit 2; }

[ -d "$APP" ] || die "no bundle at $APP (run SIGN_IDENTITY=- ./scripts/package.sh 0.0.0 1)"
APP=$(cd "$APP" && pwd -P)
PLIST=$APP/Contents/Info.plist
T=$APP/Contents/Resources/wmship
[ -f "$PLIST" ] || die "no Contents/Info.plist in $APP"

plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null
}

# ---------------------------------------------------------------- identity of the bundle
section "bundle"
case "$APP" in
  *.app) pass "bundle path ends in .app ($APP)" ;;
  *) fail "not an .app bundle: $APP" ;;
esac

PKG=$(plist_get CFBundlePackageType)
if [ "$PKG" = "APPL" ]; then
  pass "CFBundlePackageType is APPL"
else
  fail "CFBundlePackageType is '${PKG:-<missing>}', must be APPL (spctl rejects the app otherwise)"
fi

UI=$(plist_get LSUIElement)
case "$UI" in
  true|1) pass "LSUIElement is set (menu-bar app, no Dock icon)" ;;
  *) fail "LSUIElement is '${UI:-<missing>}', must be true" ;;
esac

SHORT=$(plist_get CFBundleShortVersionString)
BUILD=$(plist_get CFBundleVersion)
if [ -n "$SHORT" ]; then pass "CFBundleShortVersionString = $SHORT"; else fail "CFBundleShortVersionString is empty"; fi
if [[ "$BUILD" =~ ^[0-9]+$ ]]; then pass "CFBundleVersion = $BUILD"; else fail "CFBundleVersion is not an integer: '${BUILD:-<missing>}'"; fi

VJSON=$APP/Contents/Resources/version.json
if [ -f "$VJSON" ] && /usr/bin/python3 - "$VJSON" "$SHORT" "$BUILD" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
raise SystemExit(0 if v.get("version") == sys.argv[2] and str(v.get("build")) == sys.argv[3] else 1)
PY
then
  pass "version.json agrees with Info.plist"
else
  fail "version.json is missing or disagrees with Info.plist"
fi

BIN=$APP/Contents/MacOS/Sturgeon
if [ -x "$BIN" ]; then pass "Contents/MacOS/Sturgeon is executable"; else fail "Contents/MacOS/Sturgeon is missing or not executable"; fi
if [ -x "$APP/Contents/Resources/wmship/wmship.sh" ]; then pass "wmship.sh is executable"; else fail "wmship.sh is missing or not executable"; fi

# ---------------------------------------------------------------- signatures
section "signatures"
if codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1; then
  pass "codesign --verify --deep --strict"
else
  fail "codesign --verify --deep --strict fails"
fi

# codesign --deep is not a substitute for checking every loose Mach-O in Resources: a helper the
# release workflow forgets to sign still runs, but notarization inspects it.
MACHOS=$(find "$APP" -type f -perm -u+x -print 2>/dev/null | while IFS= read -r f; do
  /usr/bin/file -b "$f" 2>/dev/null | grep -q 'Mach-O' && printf '%s\n' "$f"
done)
NMACHO=$(printf '%s\n' "$MACHOS" | grep -c . || true)
[ "$NMACHO" -gt 0 ] || fail "no Mach-O files found under the bundle"
UNSIGNED=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  rel=${m#"$APP"/}
  if codesign -v --strict "$m" >/dev/null 2>&1; then
    pass "signed Mach-O: $rel"
  else
    fail "unsigned Mach-O: $rel"
    UNSIGNED=$((UNSIGNED + 1))
  fi
done <<< "$MACHOS"
if [ "$UNSIGNED" = 0 ] && [ "$NMACHO" -gt 0 ]; then
  pass "all $NMACHO embedded Mach-O files have a valid signature"
fi

# ---------------------------------------------------------------- helper is not a shell
section "privileged helper"
ASROOT_BIN=$T/bin/asroot
if [ -x "$ASROOT_BIN" ]; then
  if "$ASROOT_BIN" --verbs >/dev/null 2>&1; then
    pass "bin/asroot is the verb-limited helper"
  else
    fail "bin/asroot does not answer --verbs (a stale shell passthrough?)"
  fi
  if [ "$(id -u)" = 0 ]; then
    printf 'skip hostile-argv checks: running as root\n'
  else
    hostile() {  # hostile <description> <argv...>
      local desc=$1; shift
      set +e
      "$ASROOT_BIN" "$@" >/dev/null 2>&1
      local rc=$?
      set +e
      if [ "$rc" = 2 ]; then
        pass "asroot refuses $desc (exit 2)"
      else
        fail "asroot did not refuse $desc (exit $rc, wanted 2)"
      fi
    }
    hostile "no arguments"
    hostile "an interactive shell (-i)" -i
    hostile "-c id" -c id
    hostile "-c 'true; id'" -c 'true; id'
    hostile "an unknown verb (sh)" sh -c id
    hostile "a script path" /tmp/whatever.sh
    printf 'id\n' | "$ASROOT_BIN" >/dev/null 2>&1
    if [ $? = 2 ]; then pass "asroot ignores stdin (no shell)"; else fail "asroot accepted stdin"; fi
    set +e
    "$ASROOT_BIN" doctor >/dev/null 2>&1
    if [ $? = 1 ]; then
      pass "a valid verb without root says 'must run as root' (exit 1)"
    else
      fail "a valid verb without root did not report the root requirement"
    fi
    # The shipped Swift app still uses these three exact -c shapes; they must parse (exit 1 =
    # "must run as root"), not be refused as unknown (exit 2).
    LEGACY_OK=0
    for cmd in "true" \
               "/usr/bin/python3 '$T/wmship/install.py' status --json" \
               "/usr/bin/python3 '$T/wmship/install.py' cfg '{\"s\":1.0}'"; do
      "$ASROOT_BIN" -c "$cmd" >/dev/null 2>&1
      [ $? = 1 ] && LEGACY_OK=$((LEGACY_OK + 1))
    done
    if [ "$LEGACY_OK" = 3 ]; then
      pass "the app's three legacy -c shapes still parse"
    else
      fail "only $LEGACY_OK/3 legacy -c shapes parsed (the app would lose root)"
    fi
  fi
else
  fail "bin/asroot is missing or not executable"
fi

# ---------------------------------------------------------------- no build leftovers
section "no build leftovers"
LEFTOVERS=$(find "$APP" \( -name '*.o' -o -name '*.dylib' \) -print 2>/dev/null)
if [ -z "$LEFTOVERS" ]; then
  pass "no .o or .dylib files in the bundle"
else
  fail "object/library leftovers in the bundle:"
  printf '%s\n' "$LEFTOVERS" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- the layout contract
section "layout contract"
for f in BUNDLE wmship.sh wmlayout.py setup.sh teardown.sh wmlocate.py \
         wmship/install.py wmship/ctl.py wmship/wmshipd.py wmship/payload.img \
         wmship/profile.json wmship/com.stagemgr.wmshipd.plist \
         bin/asroot bin/wmx a/stagepilot; do
  if [ -e "$T/$f" ]; then pass "wmship/$f"; else fail "wmship/$f is missing"; fi
done

for pair in "install.py wmship/install.py" "ctl.py wmship/ctl.py"; do
  link=${pair%% *}; target=${pair#* }
  if [ -L "$T/$link" ] && [ "$(readlink "$T/$link")" = "$target" ]; then
    pass "wmship/$link -> $target"
  else
    fail "wmship/$link is not the expected symlink to $target"
  fi
done

# Every entry that wmlayout names must resolve inside this tree.  Run the module from the bundle
# with a scratch HOME: it is the same code the tool runs, so this catches a broken relocation.
section "wmlayout"
LAYOUT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sturgeon-selftest.XXXXXX") || die "no scratch directory"
trap 'rm -rf "$LAYOUT_TMP"' EXIT INT TERM
if HOME=$LAYOUT_TMP /usr/bin/python3 "$T/wmlayout.py" shell > "$LAYOUT_TMP/shell.txt" 2>"$LAYOUT_TMP/shell.err"; then
  pass "wmlayout.py shell exits 0"
else
  fail "wmlayout.py shell failed: $(tr '\n' ' ' < "$LAYOUT_TMP/shell.err")"
fi

if /usr/bin/python3 - "$T" "$LAYOUT_TMP/shell.txt" "$APP" <<'PY'
import json, os, shlex, sys, subprocess

tree, shell_file, app = sys.argv[1], sys.argv[2], sys.argv[3]
vals = {}
for line in open(shell_file):
    line = line.rstrip("\n")
    if not line or "=" not in line:
        continue
    k, v = line.split("=", 1)
    vals[k] = shlex.split(v)[0]

problems = []
def need(cond, msg):
    if not cond:
        problems.append(msg)

root = os.path.realpath(tree)
for key in ("LAYOUT", "ROOT", "APP", "WMSHIP", "ASROOT", "WMLOCATE", "SITES", "PROFILE",
            "STATE_DIR", "LOGS", "WMX", "WMHB", "WMCLS", "WMOBS", "R21OBS",
            "PLIST", "PLIST_LABEL", "SUDOERS", "CONSOLE_USER", "PY", "D"):
    need(key in vals and vals[key] != "", "wmlayout shell is missing %s" % key)

need(vals.get("LAYOUT") == "bundle", "LAYOUT is %r, expected 'bundle'" % vals.get("LAYOUT"))
need(os.path.realpath(vals.get("ROOT", "")) == root, "ROOT is not the bundle's wmship tree")
need(os.path.realpath(vals.get("APP", "")) == os.path.realpath(app), "APP is not this .app")
need(os.path.realpath(vals.get("WMSHIP", "")) == os.path.join(root, "wmship"),
     "WMSHIP is not <root>/wmship")
need(vals.get("PY") == "/usr/bin/python3", "PY is not /usr/bin/python3")
need(vals.get("PLIST_LABEL") == "com.stagemgr.wmshipd", "PLIST_LABEL is wrong")
need(vals.get("PLIST") == "/Library/LaunchDaemons/com.stagemgr.wmshipd.plist", "PLIST is wrong")
need(vals.get("D") == "/tmp/wmship", "D is not /tmp/wmship")
for key in ("ASROOT", "WMLOCATE", "WMX", "WMHB", "WMCLS", "WMOBS", "R21OBS"):
    p = vals.get(key, "")
    need(os.path.exists(p), "%s does not exist: %s" % (key, p))
    need(os.path.realpath(p).startswith(root + os.sep), "%s escapes the bundle: %s" % (key, p))
# PROFILE/SITES/LOGS are writable user state on purpose: <home>/Library/Application Support/Sturgeon
state = vals.get("STATE_DIR", "")
need(state.endswith(os.path.join("Library", "Application Support", "Sturgeon")),
     "STATE_DIR is not the Application Support/Sturgeon directory: %s" % state)
need(os.path.dirname(vals.get("PROFILE", "")) == state, "PROFILE is not inside STATE_DIR")
need(os.path.realpath(vals.get("LOGS", "")) == os.path.join(os.path.realpath(state), "logs"),
     "LOGS is not STATE_DIR/logs")
need(os.path.exists(os.path.join(root, "wmship", "profile.json")),
     "the bundled seed profile.json is missing")
need(vals.get("SUDOERS") == "/etc/sudoers.d/stage-pilot", "SUDOERS is not the bundle rule")

# the JSON view must agree with the shell view (one resolver, two renderings)
json_view = json.loads(subprocess.run(["/usr/bin/python3", os.path.join(root, "wmlayout.py"), "json"],
                                      capture_output=True, text=True, check=True).stdout)
for key, jkey in (("LAYOUT", "layout"), ("ROOT", "root"), ("ASROOT", "asroot"),
                  ("PLIST_LABEL", "plist_label"), ("PLIST", "plist"), ("SUDOERS", "sudoers")):
    need(vals.get(key) == str(json_view.get(jkey)), "shell/json disagree on %s" % key)

if problems:
    print("\n".join(problems), file=sys.stderr)
    raise SystemExit(1)
PY
then
  pass "wmlayout shell is a consistent bundle layout (paths exist, inside the tree, JSON agrees)"
else
  fail "wmlayout shell is not a consistent bundle layout"
fi

# ---------------------------------------------------------------- doctor refuses, never crashes
section "doctor without root"
if [ "$(id -u)" = 0 ]; then
  printf 'skip doctor: running as root; this check is for the unprivileged refusal path\n'
else
  set +e
  DOCTOR_OUT=$(HOME=$LAYOUT_TMP "$T/wmship.sh" doctor 2>&1)
  DOCTOR_RC=$?
  set +e
  if [ "$DOCTOR_RC" -le 1 ]; then
    pass "wmship.sh doctor exits $DOCTOR_RC (0 accepted, 1 refusal)"
  else
    fail "wmship.sh doctor exits $DOCTOR_RC (a crash, not a refusal)"
  fi
  printf '%s\n' "$DOCTOR_OUT" | tail -4 | sed 's/^/       /'
fi

# ---------------------------------------------------------------- result
section "result"
if [ "$FAILED" = 0 ]; then
  printf 'selftest: %d checks passed on %s\n' "$CHECKS" "$APP"
  exit 0
fi
printf 'selftest: %d of %d checks failed on %s\n' "$FAILED" "$CHECKS" "$APP" >&2
exit 1
