# AGENTS.md

Working notes for this repository. Read this before changing code.

## Layout

| path | what it is |
|---|---|
| `Package.swift` | SwiftPM manifest: the `Sturgeon` executable and the `SturgeonKit` library |
| `Sources/Sturgeon/` | the SwiftUI menu-bar shell: status item, popover, view model; owns no privilege, drives the CLI |
| `Sources/SturgeonKit/` | the non-UI core: tool-tree paths, process runner, exact command vectors, JSON decoding |
| `Tests/SturgeonKitTests/` | path, decoding and command-vector tests; need no root and no WindowManager |
| `Resources/` | `Info.plist` and `AppIcon.icns`, installed into the bundle by `scripts/build-app.sh` |
| `scripts/` | `build-helpers.sh` (helper binaries), `build-app.sh` (the bundle), `package.sh` (entry point) |
| `pack/` | release signing, notarization, stapling and the casks |
| `tools/` | proof helper `axui` and the icon generator |
| `wmship.sh` | the user-facing tool entry point (`start`, `stop`, `status`, `doctor`, `resize`, …) |
| `wmship/` | installer, capability CLI, component source, daemon, build scripts; `selftest.py` proves the memory guards |
| `helpers/asroot.c` | the privileged entry point: a fixed verb dispatcher, not a shell |
| `wmlocate.py` | resolves the patch sites from binary content |
| `wm/`, `a/` | helper sources (window probing, stage listing) |
| `homebrew/` | the cask, staged into `campfireshuffle/homebrew-tap` |
| `docs/TECHNICAL.md` | design, constraints and the per-build runbook |
| `docs/GEOMETRY.md`, `docs/RESEARCH-*.md` | the studies behind the geometry and the unmeasured assumptions |

## Build

```sh
./scripts/build-helpers.sh       # helper binaries (clang/swiftc from the command line tools)
( cd wmship && ./build.sh )      # component image
swift build -c release           # the app executable
swift test                       # the package tests (no root, no WindowManager)
./scripts/build-app.sh           # assemble dist/Sturgeon.app from .build + Resources + the tool tree
./scripts/package.sh             # app + tool, signed and packaged (ad-hoc by default)
```

## Check

```sh
./wmship.sh doctor               # resolve and validate every patch site; must pass
./wmship.sh start                # arm
./wmship.sh status               # build, ARMED, capabilities, debugger: none
./wmship.sh selfcheck            # resize preflight: probes at 1.2, then restores
./wmship.sh resize 0.6           # numeric per-tile check
./wmship.sh resize 1.0           # ratios, and x/y restoration
./wmship.sh trace                # keeper decision ring (after cfg trace=true)
./wmship.sh stop                 # restore byte-exact and verify
./wmship.sh pristine             # PRISTINE: yes
./scripts/selftest.sh            # bundle invariants; no root, no WindowManager
python3 wmship/selftest.py       # memory guards; no root, no task port
```

`doctor` has two modes with disjoint assertions: `pristine` (every site holds the on-disk image's
bytes) and `armed` (`state.json` describes this WindowManager and every site holds the recorded
stub). Auto follows `state.json`'s pid. An explicit mode the state cannot support is a refusal,
never a silent downgrade. The daemon only re-applies to a new WindowManager, so its gate is
pristine.

Leave the machine disarmed and free of debuggers when you finish. One armer at a time: two
concurrent installs invalidate each other.

## Rules that are not negotiable

**Sites and addresses**

- Patch sites are *file* virtual addresses. Runtime = file VA + the target's slide. Resolve them with
  `wmlocate.py` from content and cross-references; never add a constant, never cache a live address.
- The two SkyLight functions live in the dyld shared cache, which is slid per process. Compute their
  live address as the WindowManager's own image base plus the file offset, on every run.

**The component**

- No `objc_msgSend` from the component: dispatch is not safe in that context. Use plain C APIs or read
  the WindowManager's own structures.
- The component has no file I/O. Its control block is one page in the target process, read and written
  over the task port from outside.
- Build the component as `arm64`, not `arm64e`; authenticated calls cannot work with a raw pointer.
- Objects handed to Swift must be retained exactly once; the target owns its release.

**The strip keeper**

- A base is the pose an animation *settles* on, not a frame from the middle of it. Hovering a tile
  animates its scale entry away from rest and back; teaching mid-burst bakes that magnification into
  every later scale, and it looks like a scaling bug rather than a teaching bug.
- Gate base teaching on: strip drawn in the gutter right now (`rail_now` present, `rail_x >= 0`), no
  flush window (`front_x > 60`), scale 1.0, and outside a strip-transition hold. Refuse retract and
  departure poses geometrically. Do **not** gate base teaching on the write being our own: a
  replayed rest is byte-identical to our own last write, and excluding it makes a teach sweep learn
  nothing after on-top has run. `rp` is gated on `!ours`, because our scaled matrix must not become
  a replay.
- Poses are stored as raw bytes: cast to `double` before comparing the scale entry, or you compare a
  single mantissa byte. Translation and scale change independently, so "the pose moved" is not
  evidence of a relayout.
- The scale pivot is **derived** per accepted state document from the rail: the leftmost drawn
  **app** tile's `x` and the vertical centre of the drawn app tiles' extent. WindowManager's own
  gutter and overlay windows are excluded, because they move under the pointer. If no pivot can be
  derived, **refuse the scale** and count it (`pivmiss`) — never fall back to a constant or a guess.
  `pivot_fixed` with `qx`/`qy` is a debug override only; the shipped path writes neither.
- **Two poses per tile, and they are not interchangeable.** `base` is the resting pose and the only
  thing that may be scaled; `rp` is the replay transform used by strip-on-top and is taught from
  anything that settles while the strip is drawn. Tightening one must not blind the other: on-top
  has to work for a tile with no taught base at all.
- Both poses are **promoted after 8 state documents with no newer write for that window**
  (`SETTLE_TICKS`), never captured per write, and only while the document still says the strip is
  drawn — re-checked at promotion. Ticks are the document's seqlock generation, not wall-clock time
  or the component's call rate, so load cannot shrink the window. A base candidate a newer write
  supersedes, or one that reaches `CAND_TTL` (the wall-clock ceiling), is counted in `unsettled`.
- `base` is also the largest `m0` the tile shows (a hover lift is the smaller value). It is dropped
  when the strip leaves **and when the rail's app-tile id-set changes while the strip is drawn**: an
  in-place relayout is a new drawing, and bases from the old one are stale. The key is compared
  across state documents and adopted after two agree; WindowManager's gutter windows are excluded.
  A change clears every base and the next settled write becomes the base. `rp` is untouched, so
  on-top survives it.
- `rp` survives a hide and refuses a candidate written before the last reveal. The margins are
  measured: longest in-animation gap 0.13 s ≈ 5 documents, post-rest silence ≥0.3 s.
- Never write a page that is not already writable, and never leave a page a branch points into
  without execute permission. Both are `KERN_PROTECTION_FAILURE` inside `WindowManager`, and the
  installer refuses rather than trying (`wmship/selftest.py` proves the guard without root).
- Act only on a complete state document: `flush` and `rail_now` must be present and fresh. The
  document is published through a seqlock; read the length, then retry if the generation moves.

**Privilege and distribution**

- The only root path is `bin/asroot`, a **fixed verb dispatcher, not a shell**. It accepts the verbs
  published by `asroot --verbs`, validates each argument by shape (scale 0.4–1.5, decimal window id,
  JSON object under 8 KiB, printable stage), and derives every path from its own location plus
  `/tmp/wmship`. No `-c`, no stdin, no inherited environment. The three legacy `-c` shapes the app
  still sends are matched exactly and are the only exception.
- A new privileged action is a **new verb** in `helpers/asroot.c`, in the dispatch table and in
  `--verbs` — never a wider argument to an existing one. `./scripts/selftest.sh` fails on a `-c`
  passthrough or a direct `install.py`/`ctl.py` call in the shipped shell scripts, so route callers
  through verbs.
- Root, SIP off and `task_for_pid` are the floor. No debugger entitlement is required; do not add
  `com.apple.security.cs.debugger`.
- Sign every embedded Mach-O before signing the app, with hardened runtime and a timestamp.
- `CFBundlePackageType` must be `APPL`, or `spctl` reports a correctly signed app as "does not seem
  to be an app".
- The cask's `uninstall` boots out the LaunchDaemon and removes the sudoers rule; `zap` clears
  `/tmp/wmship` and the Application Support directory.

**Testing**

- No synthetic clicks or drags, and do not rearrange the user's stages or windows. The one accepted
  pointer input is `wmship.sh resize`, which sweeps the tiles because that is the shipped path.
- Before offering or claiming resize works, run `wmship.sh selfcheck`. It applies a 1.2 probe with
  teaching off, requires every tile within 2%, then restores the caller's scale; the strip visibly
  scales for a few seconds. The app runs it when the popover opens and withholds the size slider
  until it passes; the pass path on a live armed install is still an owner check.
- A tile with no resting base is **skipped, not a command-wide refusal**. `resize` scales the tiles
  that have one and reports `no_base`, `scaled`, `not_scaled` and `partial`; a non-1.0 scale is
  never `ok` when a tile was skipped. Only a pass with no strip tiles at all refuses.
- The app's diagnostics panel, gesture resize and drop-to-tile paths are unit-tested at their pure
  seams only; none has been exercised against an armed WindowManager. Label them implemented but
  unverified.
- `cfg trace=true` is diagnostic and **write-only**: the keeper writes one record per decision to a
  16 KB ring, no branch reads `io_tr`, and `wmship/selftest.py` asserts that. Read it with
  `wmship.sh trace [--reset]`; the field legend is in `docs/TECHNICAL.md`. It cannot change a
  decision, but turn it off when the diagnosis is done. The app's **Pose trace** toggle writes
  `trace`, and **Show trace** reads the ring; an older component shows `unavailable`, not an empty
  table.
- Verify with numbers (window layers, per-tile geometry), not with screenshots of intent.

## Keeping up with macOS

`wmlocate.py` locates six sites structurally: the two `bl` call sites, the driver entry they target,
the compute callee, and the two SkyLight transform functions. Every candidate is checked against
instruction class and cross-references; anything ambiguous is a named refusal.

When a new build appears:

1. `./wmship.sh doctor` and read the refusal — it names the site or the missing profile.
2. Sites resolve but the object layout changed → re-derive the build profile with `wmship/wmcls` and
   add it to `wmship/profile.json` under `<CFBundleVersion>|<sha256 of __TEXT>`.
3. A site no longer matches → update the structural signature in `wmlocate.py`, then prove it against
   a shifted copy of the binary and a corrupted copy that must refuse.
4. Rebuild the component. Before releasing, confirm `pivmiss` stays 0 and `psrc` is 1 across a resize,
   and use `cfg trace=true` + `wmship.sh trace` to check that a hover still returns to a settled
   value and a hide still translates without changing `m0`. If the rail yields no pivot, fix the
   derivation; do not pin the old constant. Then run the four capability checks.

`sites.json` and `profile.json` are the supported-build record. Keep both in the repo.

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Run the **Release** workflow with that version; it refuses a mismatch.
3. The workflow signs with Developer ID, notarizes, staples, publishes the zip and its sha256, and
   opens a PR against the tap with the updated cask.
