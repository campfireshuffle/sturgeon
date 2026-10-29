#!/bin/zsh
# package.sh — the RELEASE entry point: build Sturgeon.app, sign it with the Developer ID, notarize
# and staple it, zip the *stapled* bundle, and (re)generate the Homebrew casks.
#
#   ./pack/package.sh [version] [build]
#
# The app is built by scripts/build-app.sh (SwiftPM + Resources/ + the tool tree), which leaves
# dist/Sturgeon.app. This script post-processes that bundle (assembled tool tree included) and owns
# everything a release needs and a dev build does not:
#
#   * inside-out signing of every Mach-O — hardened runtime + timestamp, no entitlements (root with
#     SIP off already has task_for_pid against WindowManager; see AGENTS.md)
#   * notarization (notarytool --wait), stapling, and an spctl assessment of the stapled bundle
#   * the artifact name: art/sturgeon-<version>-macos-arm64.zip, zipped AFTER stapling, with the
#     sha256 taken from that zip (a cask sha of a pre-staple zip is a lie)
#   * the two casks: homebrew/Casks/sturgeon.rb (release url, the tap copy) and
#     homebrew/Casks/sturgeon-local.rb (file:// artifact, for a pre-release local install proof)
#
# Identity and notary credentials, in order of precedence:
#   SIGN_IDENTITY, SIGN_KEYCHAIN            (codesign --sign / --keychain)
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#   defaults: the Developer ID in the keychain, and ~/.sturgeon-signing/{AuthKey_*.p8,key-id.txt,
#             issuer-id.txt}.  No key material is ever printed or copied into this repository.
#
# With no Developer ID available the build falls back to an ad-hoc signature (SIGN_IDENTITY=-) and
# says so: runnable locally, NOT distributable, NOT notarisable.
#
# Releases are cut by the Release workflow, which keeps its credentials as repository secrets. That
# is the supported path; a local run needs nothing on this machine.
set -eu
SELF=${0:A}
PACK=${SELF:h}
WORK=${PACK:h}
ART=$WORK/art
APPNAME=Sturgeon
VERSION=${1:-1.0.0}
BUILD=${2:-35}
ZIP=$ART/sturgeon-$VERSION-macos-arm64.zip
CASK_IN=$WORK/homebrew/Casks/sturgeon.rb.in
CASK_OUT=$WORK/homebrew/Casks/sturgeon.rb
CASK_LOCAL=$WORK/homebrew/Casks/sturgeon-local.rb
CREDS=${STURGEON_CREDS:-$HOME/.sturgeon-signing}

say() { print -r -- "package: $*" }

# ---------------------------------------------------------------- identity
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  found="$( security find-identity -v -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} 2>/dev/null \
            | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' | head -1 )"
  if [[ -n "$found" ]]; then
    SIGN_IDENTITY="$found"
  else
    SIGN_IDENTITY="-"
  fi
fi
DISTRIBUTABLE=0
[[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]] && DISTRIBUTABLE=1
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  say "identity: ad-hoc (no Developer ID in the keychain) — runnable, NOT distributable, NOT notarisable"
else
  say "identity: $SIGN_IDENTITY"
fi
[[ -n "${SIGN_KEYCHAIN:-}" ]] && say "keychain: $SIGN_KEYCHAIN"

sign_flags=(--force --sign "$SIGN_IDENTITY")
[[ -n "${SIGN_KEYCHAIN:-}" ]] && sign_flags+=(--keychain "$SIGN_KEYCHAIN")
[[ "$SIGN_IDENTITY" != "-" ]] && sign_flags+=(--options runtime --timestamp)
sign_one() {  # sign_one <path> [entitlements]
  if [[ -n "${2:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    codesign "${sign_flags[@]}" --entitlements "$2" "$1" >/dev/null 2>&1 \
      || { say "REFUSING: codesign failed on $1" >&2; exit 1; }
  else
    codesign "${sign_flags[@]}" "$1" >/dev/null 2>&1 \
      || { say "REFUSING: codesign failed on $1" >&2; exit 1; }
  fi
}

# ---------------------------------------------------------------- notary credentials
notary_ready() {
  [[ $DISTRIBUTABLE == 1 ]] || return 1
  NOTARY_KEY=${NOTARY_KEY:-$(ls $CREDS/AuthKey_*.p8 2>/dev/null | head -1)}
  NOTARY_KEY_ID=${NOTARY_KEY_ID:-$(cat $CREDS/key-id.txt 2>/dev/null | tr -d '[:space:]')}
  NOTARY_ISSUER=${NOTARY_ISSUER:-$(cat $CREDS/issuer-id.txt 2>/dev/null | tr -d '[:space:]')}
  [[ -f "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]
}

mkdir -p $ART
rm -rf $ART/$APPNAME.app $ZIP $ZIP.sha256

# ---------------------------------------------------------------- 1. the app
say "app: scripts/build-app.sh (SwiftPM)"
( cd $WORK && SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/build-app.sh "$VERSION" "$BUILD" ) \
  || { say "scripts/build-app.sh failed" >&2; exit 1; }
[[ -d $WORK/dist/$APPNAME.app ]] || { say "build-app.sh produced no dist/$APPNAME.app" >&2; exit 1; }
/usr/bin/ditto $WORK/dist/$APPNAME.app $ART/$APPNAME.app
APP=$ART/$APPNAME.app
T=$APP/Contents/Resources/wmship

# ---------------------------------------------------------------- 1b. the dev artifacts
# ./scripts/package.sh has always left a runnable bundle, a zip and a cask in dist/ — the local
# install proof reads them. The release artifact is the stapled zip in art/.
[[ -f $CASK_IN ]] || { say "missing $CASK_IN" >&2; exit 1; }
DEVZIP=$WORK/dist/$APPNAME-$VERSION.zip
rm -f $DEVZIP $DEVZIP.sha256
/usr/bin/ditto -c -k --sequesterRsrc --keepParent $WORK/dist/$APPNAME.app $DEVZIP
DEV_SHA=$(shasum -a 256 $DEVZIP | cut -d' ' -f1)
print -r -- "$DEV_SHA  $DEVZIP" > $DEVZIP.sha256
sed -e "s|@@VERSION@@|$VERSION|g" -e "s|@@SHA256@@|$DEV_SHA|g" \
    -e "s|@@URL@@|file://$DEVZIP|g" $CASK_IN > $WORK/dist/sturgeon.rb
say "dist zip: $DEVZIP"
say "dist cask: $WORK/dist/sturgeon.rb"

# ---------------------------------------------------------------- 2. contract check
for f in BUNDLE wmship.sh wmlayout.py setup.sh teardown.sh wmlocate.py \
         wmship/install.py wmship/ctl.py wmship/wmshipd.py wmship/payload.img \
         wmship/profile.json bin/asroot bin/wmx a/stagepilot; do
  [[ -e $T/$f ]] || { say "REFUSING: the bundle is missing $f (layout contract)" >&2; exit 1; }
done
# The notary service signs off every Mach-O in the bundle; an unsigned .o file is a rejection
# waiting to happen and nothing at runtime reads it (it is only an input to build.sh).
rm -f $T/wmship/*.o(N) $T/wmship/*.dylib(N)
say "layout: contract satisfied (wmship/, wm/, bin/, a/ present)"

# ---------------------------------------------------------------- 3. version + package type
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" $APP/Contents/Info.plist
# spctl rejects a correctly signed app without it: "the code is valid but does not seem to be an app"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" $APP/Contents/Info.plist 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" $APP/Contents/Info.plist
print -r -- "{\"version\":\"$VERSION\",\"build\":\"$BUILD\"}" > $APP/Contents/Resources/version.json
say "version.json: $(cat $APP/Contents/Resources/version.json)"

# ---------------------------------------------------------------- 4. sign, inside out
for b in $T/bin/asroot $T/bin/wmx $T/wmship/wmhb $T/wmship/wmcls \
         $T/bin/r19ax $T/bin/r8state $T/bin/r21probe $T/bin/r21move $T/bin/r21scroll \
         $T/bin/r21gesture $T/bin/r21obs $T/bin/r20click $T/a/stagepilot \
         $T/wm/wmobs $T/wm/wmkey $APP/Contents/MacOS/$APPNAME; do
  [[ -e $b ]] && sign_one "$b"
done
sign_one "$APP"
codesign --verify --deep --strict --verbose=2 $APP >/dev/null 2>&1 \
  && say "signature: verifies (deep, strict)" || { say "REFUSING: signature does not verify" >&2; exit 1; }
if [[ $DISTRIBUTABLE == 1 ]]; then
  say "entitlements: none (root + SIP off is sufficient for the task port)"
fi

# ---------------------------------------------------------------- 5. notarize + staple
NOTARIZED=0
SUBMISSION=""
if notary_ready; then
  say "notarizing (notarytool --wait, key $CREDS/AuthKey_*.p8)…"
  SUB=$ART/$APPNAME-notarization.zip
  /usr/bin/ditto -c -k --keepParent $APP $SUB
  OUT=$(xcrun notarytool submit "$SUB" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER" --wait 2>&1) || true
  print -r -- "$OUT" | tail -4
  SUBMISSION=$(print -r -- "$OUT" | sed -n 's/^ *id: *//p' | head -1)
  if print -r -- "$OUT" | grep -q "status: Accepted"; then
    xcrun stapler staple $APP >/dev/null && say "stapled"
    xcrun stapler validate $APP >/dev/null && say "staple validates"
    NOTARIZED=1
  else
    say "REFUSING: notarization was not Accepted (see above). Not shipping an unnotarised artifact as a release."
    exit 1
  fi
  rm -f $SUB
else
  if [[ $DISTRIBUTABLE == 1 ]]; then
    say "WARNING: signed with a Developer ID but no notary credentials — not notarising"
  else
    say "notarization: skipped (ad-hoc build)"
  fi
fi

if [[ $NOTARIZED == 1 ]]; then
  if spctl --assess --type execute --verbose=2 $APP 2>&1 | tee $ART/spctl.txt | grep -q "accepted"; then
    say "spctl: $(tail -1 $ART/spctl.txt)"
  else
    say "REFUSING: spctl rejects the stapled app: $(tail -1 $ART/spctl.txt)"; exit 1
  fi
fi

# ---------------------------------------------------------------- 6. zip AFTER stapling
/usr/bin/ditto -c -k --sequesterRsrc --keepParent $APP $ZIP
SHA=$(shasum -a 256 $ZIP | cut -d' ' -f1)
print -r -- "$SHA  $(basename $ZIP)" > $ZIP.sha256
say "zip: $ZIP"
say "sha256: $SHA"
if [[ -n $SUBMISSION ]]; then
  print -r -- "notarization submission: $SUBMISSION" > $ART/NOTARIZATION.txt
  print -r -- "spctl: $(tail -1 $ART/spctl.txt)" >> $ART/NOTARIZATION.txt
  say "submission: $SUBMISSION"
fi

# ---------------------------------------------------------------- 7. casks
[[ -f $CASK_IN ]] || { say "missing $CASK_IN" >&2; exit 1; }
sed -e "s|@@VERSION@@|$VERSION|g" -e "s|@@SHA256@@|$SHA|g" \
    -e "s|@@URL@@|https://github.com/campfireshuffle/sturgeon/releases/download/v#{version}/sturgeon-#{version}-macos-arm64.zip|g" \
    $CASK_IN > $CASK_OUT
sed -e "s|@@VERSION@@|$VERSION|g" -e "s|@@SHA256@@|$SHA|g" \
    -e "s|@@URL@@|file://$ZIP|g" $CASK_IN > $CASK_LOCAL
say "cask: $CASK_OUT  (release url — the copy staged in campfireshuffle/homebrew-tap)"
say "cask: $CASK_LOCAL  (file:// — a pre-release local install proof)"
say "done (identity=$SIGN_IDENTITY, distributable=$DISTRIBUTABLE, notarized=$NOTARIZED)"
