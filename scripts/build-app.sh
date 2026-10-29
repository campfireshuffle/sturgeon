#!/bin/zsh
# build-app.sh — build the menu-bar app with SwiftPM and assemble Sturgeon.app.
#
#   ./scripts/build-app.sh [version] [build]        # default 1.0.0 / 35
#
# Produces dist/Sturgeon.app from:
#
#   .build/release/Sturgeon                 the executable
#   Resources/Info.plist  AppIcon.icns      the bundle metadata and icon
#   the tool tree                            wmship.sh, wmlayout.py, setup.sh, teardown.sh,
#                                            wmlocate.py, wmship/, wm/, bin/, a/stagepilot
#
# The tool tree is *injected*, not built here: run scripts/build-helpers.sh and
# wmship/build.sh first (the release workflow does). The bundle path is the runtime contract in
# Sources/SturgeonKit/Paths.swift, so nothing below may rename or move it.
#
# Signing: SIGN_IDENTITY defaults to "-" (ad-hoc), which is what the local proof uses. A release
# build sets SIGN_IDENTITY="Developer ID Application: …" and this script then signs with the
# hardened runtime and a timestamp, ready for notarization (which pack/package.sh owns).
set -eu
SELF=${0:A}
HERE=${SELF:h}
WORK=${HERE:h}
VERSION=${1:-1.0.0}
BUILDNO=${2:-35}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
DIST=$WORK/dist
APPNAME=Sturgeon
APP=$DIST/$APPNAME.app

say() { print -r -- "build-app: $*" }

if ! xcrun --find swift >/dev/null 2>&1; then
  say "swift not found (Xcode command line tools required)" >&2
  exit 1
fi

# ---------------------------------------------------------------- 1. SwiftPM
say "swift build -c release"
( cd $WORK && swift build -c release )
BIN=$(cd $WORK && swift build -c release --show-bin-path)/$APPNAME
[ -x $BIN ] || { say "SwiftPM produced no $BIN" >&2; exit 1; }

# ---------------------------------------------------------------- 2. bundle skeleton
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/$APPNAME
cp $WORK/Resources/Info.plist $APP/Contents/Info.plist
cp $WORK/Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
print -r -- "APPL????" > $APP/Contents/PkgInfo

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILDNO" $APP/Contents/Info.plist
print -r -- "{\"version\":\"$VERSION\",\"build\":\"$BUILDNO\"}" > $APP/Contents/Resources/version.json
plutil -lint $APP/Contents/Info.plist >/dev/null

# ---------------------------------------------------------------- 3. the tool tree
# Layout contract (shared with wmlayout.py, which derives every runtime path from its own
# location — nothing here is a repo path at runtime):
#
#   Sturgeon.app/Contents/Resources/wmship/
#     BUNDLE                                  layout marker
#     wmship.sh wmlayout.py setup.sh teardown.sh wmlocate.py
#     install.py -> wmship/install.py   ctl.py -> wmship/ctl.py
#     wmship/  install.py ctl.py wmshipd.py wmhb wmcls payload.img payload.syms.json
#              profile.json com.stagemgr.wmshipd.plist
#              (island.o is an input to build.sh, never a runtime file: notarization inspects
#               every Mach-O in the bundle, so no .o may be copied in)
#     wm/      wmobs wmkey wmctl.py wm.py
#     bin/     asroot wmx r19ax r8state r21probe r21move r20click r21scroll r21gesture r21obs
#     a/       stagepilot               (the AX stage lister the app's Move menu reads)
T=$APP/Contents/Resources/wmship
mkdir -p $T/wmship $T/wm $T/bin $T/a
print -r -- "Sturgeon bundle — wmlayout.py selects the app layout when this marker exists" > $T/BUNDLE

for f in wmship.sh wmlayout.py setup.sh teardown.sh wmlocate.py; do
  cp $WORK/$f $T/$f
  chmod 0755 $T/$f
done

for f in install.py ctl.py wmshipd.py wmhb wmcls payload.img payload.syms.json \
         profile.json com.stagemgr.wmshipd.plist; do
  [ -e $WORK/wmship/$f ] || { say "missing required file wmship/$f (run scripts/build-helpers.sh and wmship/build.sh)" >&2; exit 1; }
  cp $WORK/wmship/$f $T/wmship/$f
done
chmod 0755 $T/wmship/install.py $T/wmship/ctl.py $T/wmship/wmshipd.py $T/wmship/wmhb $T/wmship/wmcls

# the contract names install.py / ctl.py at the top of the tree too (realpath -> the one copy)
ln -sf wmship/install.py $T/install.py
ln -sf wmship/ctl.py $T/ctl.py

for f in wmobs wmkey wmctl.py wm.py; do cp $WORK/wm/$f $T/wm/$f; done
chmod 0755 $T/wm/wmobs $T/wm/wmkey

for f in asroot wmx r19ax r8state r21probe r21move r21scroll r21gesture r21obs r20click; do
  [ -x $WORK/bin/$f ] || { say "missing required helper bin/$f (run scripts/build-helpers.sh)" >&2; exit 1; }
  cp $WORK/bin/$f $T/bin/$f
done
cp $WORK/bin/stagepilot $T/a/stagepilot
chmod 0755 $T/bin/* $T/a/stagepilot

# ---------------------------------------------------------------- 4. relocation guard
# The shipped tree must not name the developer's checkout: wmlayout derives the layout, and the
# app's Paths resolver does the same. A single absolute repo path here would be a relocation bug
# that only shows up on the user's machine.
OFFENDERS=$(grep -RIn "/Users/" $T --include='*.sh' --include='*.py' \
            --include='*.plist' --include='*.json' 2>/dev/null | grep -v '^Binary' || true)
if [ -n "$OFFENDERS" ]; then
  say "REFUSING: the bundled tree still contains an absolute checkout path:" >&2
  print -r -- "$OFFENDERS" >&2
  exit 1
fi
if strings $APP/Contents/MacOS/$APPNAME | grep -q "/Users/"; then
  say "REFUSING: the app binary contains an absolute user path" >&2
  exit 1
fi
say "relocation guard: no /Users path in the tree or the binary"

# Notarization signs off every Mach-O in the bundle, and nothing at runtime reads an object file.
# This used to be stripped only by pack/package.sh, so dist/ shipped wmship/island.o while art/
# did not. Refuse at assembly instead, so every bundle we hand out has the same contents.
LEFTOVERS=$(find $T \( -name '*.o' -o -name '*.dylib' \) -print 2>/dev/null)
[ -z "$LEFTOVERS" ] || { say "REFUSING: object/dylib leftovers in the bundle:" >&2; print -r -- "$LEFTOVERS" >&2; exit 1; }

# ---------------------------------------------------------------- 5. sign
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - --timestamp=none $APP >/dev/null 2>&1 \
    && say "signed ad-hoc (SIGN_IDENTITY=-) — NOT notarised" \
    || say "WARNING: ad-hoc signing failed"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" $APP >/dev/null
  say "signed: $SIGN_IDENTITY (hardened runtime, timestamped)"
fi

say "$APP"
