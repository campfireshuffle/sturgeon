#!/bin/zsh
# build.sh — payload image (near island + far body) for the current WindowManager build.
#
# Both halves are built as *arm64*, not arm64e: the image is raw code copied into the WM, and
# arm64e C emits `blraaz` for every call through a function pointer, which authenticates a raw
# slot value with the calling process's key IA and always fails (EXC_ARM_PAC_FAIL). Plain arm64
# `blr` interoperates with the WM's arm64e callees: the callee's own `pacibsp`/`retab` pair signs
# and authenticates the LR it was given. The two arm64e-only instructions the island replays
# (`bti c`, `pacibsp`) are emitted as words.
set -eu
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
# NO_RAILCHG=1 builds the *negative control* for the stale-base trial: the layout-invalidation
# block (issues #4) is compiled out, so a tile set that shrinks in place keeps its stale bases.
# The shipped image never defines it; the trial builds both and diffs the per-tile ratios.
DEFS=""
[ "${NO_RAILCHG:-0}" = "1" ] && DEFS="-DWM_NO_RAILCHG"
clang -O2 -arch arm64 -ffreestanding -fno-builtin -fno-stack-protector $DEFS \
      -fno-asynchronous-unwind-tables -fno-unwind-tables -Wno-int-conversion \
      -c payload.c -o payload.o
clang -arch arm64 -c island.s -o island.o
clang -arch arm64 -dynamiclib -nostdlib -Wl,-syslibroot,$SDK -lSystem \
      -Wl,-install_name,/nonexistent -o payload.dylib payload.o island.o
python3 extract.py payload.dylib payload.img payload.syms.json

# the helper half is a separate process (root, no debugger): rebuild it too, so the shipped
# artifacts and their sources never disagree.
clang -O2 -arch arm64 -o wmhb wmhb.c
