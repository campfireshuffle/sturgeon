#!/bin/zsh
# package.sh — build Sturgeon.app, inject the privileged tool tree exactly as wmlayout.py expects
# it, and produce the Homebrew artifacts:
#
#   dist/Sturgeon.app                       the shipping bundle (relocatable)
#   dist/Sturgeon-<version>.zip             the download
#   dist/Sturgeon-<version>.zip.sha256
#   dist/sturgeon.rb                        the cask (same content as the tap copy)
#   homebrew/Casks/sturgeon.rb              tap file, not published
#
#   ./package.sh [version] [build]
#
# SIGN_IDENTITY is "-" (ad-hoc) by default, which is what the local proof uses.  Release CI sets
# SIGN_IDENTITY="Developer ID Application: …"; this script then signs with the hardened runtime
# and a timestamp so notarytool can notarise and stapler can staple.  Notarization is not done
# here.
#
# Layout contract (shared with wmlayout.py, which derives every runtime path from its own
# location — nothing here is a repo path at runtime):
#
#   Sturgeon.app/Contents/Resources/wmship/
#     BUNDLE                                  layout marker
#     wmship.sh wmlayout.py setup.sh teardown.sh wmlocate.py
#     install.py -> wmship/install.py   ctl.py -> wmship/ctl.py
#     wmship/  install.py ctl.py wmshipd.py wmhb wmcls payload.img payload.syms.json
#              island.o profile.json com.stagemgr.wmshipd.plist
#     wm/      wmobs wmkey wmctl.py wm.py
#     bin/     asroot wmx r19ax r8state r21probe r21move r20click r21scroll r21gesture r21obs
#     a/       stagepilot               (the AX stage lister the app's Move menu reads)
#
# The app resolves the tree with Sources/Paths.swift: Bundle.main.resourceURL/wmship when bundled,
# else by walking up to the repo's work dir.  Its binary contains no user path.
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
ZIP=$DIST/$APPNAME-$VERSION.zip
CASK_IN=$WORK/homebrew/Casks/sturgeon.rb.in
CASK_OUT=$WORK/homebrew/Casks/sturgeon.rb

say() { print -r -- "package: $*" }

# ---------------------------------------------------------------- 1. the Swift app
( cd $HERE && SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh )
SRCAPP=$HERE/build/$APPNAME.app
[ -d $SRCAPP ] || { say "build.sh produced no $SRCAPP" >&2; exit 1 }

# ---------------------------------------------------------------- 2. stage the bundle
rm -rf $APP $ZIP
mkdir -p $APP
/usr/bin/ditto $SRCAPP $APP
T=$APP/Contents/Resources/wmship
mkdir -p $T/wmship $T/wm $T/bin $T/a
print -r -- "Sturgeon bundle — wmlayout.py selects the app layout when this marker exists" > $T/BUNDLE

for f in wmship.sh wmlayout.py setup.sh teardown.sh wmlocate.py; do
  cp $WORK/$f $T/$f
  chmod 0755 $T/$f
done

for f in install.py ctl.py wmshipd.py wmhb wmcls payload.img payload.syms.json island.o \
         profile.json com.stagemgr.wmshipd.plist; do
  [ -e $WORK/wmship/$f ] || { say "missing required file wmship/$f" >&2; exit 1 }
  cp $WORK/wmship/$f $T/wmship/$f
done
chmod 0755 $T/wmship/install.py $T/wmship/ctl.py $T/wmship/wmshipd.py $T/wmship/wmhb $T/wmship/wmcls

# the contract names install.py / ctl.py at the top of the tree too (realpath -> the one copy)
ln -sf wmship/install.py $T/install.py
ln -sf wmship/ctl.py $T/ctl.py

for f in wmobs wmkey wmctl.py wm.py; do cp $WORK/wm/$f $T/wm/$f; done
chmod 0755 $T/wm/wmobs $T/wm/wmkey

cp $WORK/bin/asroot        $T/bin/asroot
cp $WORK/bin/wmx           $T/bin/wmx
cp $WORK/bin/r19ax         $T/bin/r19ax
cp $WORK/bin/r8state       $T/bin/r8state
cp $WORK/bin/r21probe     $T/bin/r21probe
cp $WORK/bin/r21move      $T/bin/r21move
cp $WORK/bin/r21scroll    $T/bin/r21scroll
cp $WORK/bin/r21gesture   $T/bin/r21gesture
cp $WORK/bin/r21obs       $T/bin/r21obs
cp $WORK/bin/r20click      $T/bin/r20click
cp $WORK/bin/stagepilot    $T/a/stagepilot
chmod 0755 $T/bin/* $T/a/stagepilot

print -r -- "{\"version\":\"$VERSION\",\"build\":\"$BUILDNO\"}" > $APP/Contents/Resources/version.json
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILDNO" $APP/Contents/Info.plist

# ---------------------------------------------------------------- 3. relocation guard
# The shipped tree must not name the developer's checkout: wmlayout derives the layout, and the
# app's Paths.swift does the same.  A single absolute repo path here would be a relocation bug
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

# ---------------------------------------------------------------- 4. sign + zip
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - --timestamp=none $APP >/dev/null 2>&1 \
    && say "signed ad-hoc (local proof; NOT notarised)" || say "WARNING: ad-hoc signing failed"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" $APP >/dev/null
  say "signed: $SIGN_IDENTITY (hardened runtime, timestamped)"
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent $APP $ZIP
SHA=$(shasum -a 256 $ZIP | cut -d' ' -f1)
print -r -- "$SHA  $ZIP" > $DIST/$APPNAME-$VERSION.zip.sha256
say "zip: $ZIP"
say "sha256: $SHA"

# ---------------------------------------------------------------- 5. cask
[ -f $CASK_IN ] || { say "missing $CASK_IN" >&2; exit 1; }
URL="file://$ZIP"
sed -e "s|@@VERSION@@|$VERSION|g" -e "s|@@SHA256@@|$SHA|g" -e "s|@@URL@@|$URL|g" \
    $CASK_IN > $CASK_OUT
cp $CASK_OUT $DIST/sturgeon.rb
say "cask: $CASK_OUT"
say "cask: $DIST/sturgeon.rb"
say "done — $APPNAME $VERSION ($BUILDNO)"
