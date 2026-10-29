#!/bin/zsh
# build.sh — compile Sturgeon.app from the Swift sources with swiftc.  No Xcode project, no
# package dependencies, no network.  Produces work/companion/build/Sturgeon.app.
#
# The app is a shell: the privileged tool tree is injected by package.sh at
# Contents/Resources/wmship (the layout contract in Sources/Paths.swift).  Launched from this
# build directory, Paths falls back to the repo's work dir by walking up from the executable, so
# the same binary is testable before packaging.
#
# Signing: SIGN_IDENTITY defaults to "-" (ad-hoc), which is what the local proof uses.  A release
# build sets SIGN_IDENTITY="Developer ID Application: …" and this script then signs with the
# hardened runtime and a timestamp, ready for notarization (which is CI's job, not this script's).
set -eu
SELF=${0:A}
HERE=${SELF:h}
OUT=$HERE/build
APP=$OUT/Sturgeon.app
VERSION=${STURGEON_VERSION:-1.0.0}
BUILDNO=${STURGEON_BUILD:-35}
SIGN_IDENTITY=${SIGN_IDENTITY:--}

if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -r -- "build.sh: swiftc not found (Xcode command line tools required)" >&2
  exit 1
fi

rm -rf $OUT
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources

print -r -- "build.sh: swiftc $(xcrun swiftc --version 2>&1 | tail -1 | sed 's/^.*Apple //')"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  -module-name Sturgeon \
  -o $APP/Contents/MacOS/Sturgeon \
  $HERE/Sources/*.swift

# ---------------------------------------------------------------- icon
ICONSET=$OUT/AppIcon.iconset
mkdir -p $ICONSET
xcrun swiftc -O -target arm64-apple-macosx14.0 -o $OUT/makeicon $HERE/tools/makeicon.swift >/dev/null
$OUT/makeicon $OUT/icon-1024.png >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s $OUT/icon-1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  d=$((s * 2))
  sips -z $d $d $OUT/icon-1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
rm -rf $ICONSET $OUT/icon-1024.png $OUT/makeicon

# ---------------------------------------------------------------- Info.plist
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Sturgeon</string>
	<key>CFBundleIdentifier</key><string>run.lil.sturgeon</string>
	<key>CFBundleName</key><string>Sturgeon</string>
	<key>CFBundleDisplayName</key><string>Sturgeon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILDNO</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>© 2026 Sarim Abbas. All rights reserved.</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
print -r -- "APPL????" > $APP/Contents/PkgInfo
plutil -lint $APP/Contents/Info.plist >/dev/null

# ---------------------------------------------------------------- sign
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - --timestamp=none $APP >/dev/null 2>&1 \
    && print -r -- "build.sh: signed ad-hoc (SIGN_IDENTITY=-) — NOT notarised" \
    || print -r -- "build.sh: WARNING unsigned"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" $APP >/dev/null
  print -r -- "build.sh: signed with '$SIGN_IDENTITY' (hardened runtime, timestamped)"
fi

print -r -- "build.sh: $APP"
