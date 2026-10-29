#!/bin/zsh
# Builds every auxiliary binary the tool calls out to, from the sources in this repository.
#
#   ./scripts/build-helpers.sh
#
# Output layout matches what wmlayout.py expects:
#   bin/        flat helpers (wmx, the AX/window/stage probes, asroot)
#   wm/         wmobs, wmkey
#   wmship/     wmhb, wmcls
#
# Everything is arm64. The payload itself is built separately by wmship/build.sh.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
SDK=$(xcrun --show-sdk-path)
CC_FLAGS=(-O2 -arch arm64)

say() { print -r -- "$@" }

mkdir -p "$ROOT/bin"

build_c() {   # name, source
  say "  cc   $1"
  clang "${CC_FLAGS[@]}" -o "$ROOT/bin/$1" "$ROOT/helpers/$2"
}

build_swift() { # name, source, output-dir
  say "  swift $1"
  swiftc -O -target arm64-apple-macos14.0 -o "$3/$1" "$2"
}

say "helpers:"
build_c wmx wmx.c
for pair in "r19ax:r19ax.swift" "r21obs:r21obs.swift" "r21move:r21move.swift" \
            "r21scroll:r21scroll.swift" "r21gesture:r21gesture.swift" \
            "r8state:r8state.swift" "r20click:r20click.swift"; do
  build_swift "${pair%%:*}" "$ROOT/helpers/${pair#*:}" "$ROOT/bin"
done
build_swift r21probe "$ROOT/helpers/probe.swift" "$ROOT/bin"
build_swift stagepilot "$ROOT/a/stagepilot.swift" "$ROOT/bin"

say "wm:"
build_swift wmobs "$ROOT/wm/wmobs.swift" "$ROOT/wm"
build_swift wmkey "$ROOT/wm/wmkey.swift" "$ROOT/wm"

say "wmship:"
clang "${CC_FLAGS[@]}" -o "$ROOT/wmship/wmhb" "$ROOT/wmship/wmhb.c"
clang "${CC_FLAGS[@]}" -o "$ROOT/wmship/wmcls" "$ROOT/wmship/wmcls.c"

# the privileged entry point: a compiled verb dispatcher, not a shell passthrough.  It derives the
# tool tree from its own real path (bin/asroot -> the tree), so it must be installed at bin/asroot.
say "  cc   asroot"
clang "${CC_FLAGS[@]}" -o "$ROOT/bin/asroot" "$ROOT/helpers/asroot.c"

say "built: $(ls "$ROOT/bin" | tr '\n' ' ')"
