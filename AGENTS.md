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
| `wmship/` | installer, capability CLI, payload source, daemon, build scripts |
| `wmlocate.py` | resolves the patch sites from binary content |
| `wm/`, `a/` | helper sources (window probing, stage listing) |
| `homebrew/` | the cask, staged into `campfireshuffle/homebrew-tap` |
| `docs/TECHNICAL.md` | design, constraints and the per-build runbook |

## Build

```sh
./scripts/build-helpers.sh       # helper binaries (clang/swiftc from the command line tools)
( cd wmship && ./build.sh )      # payload image
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
./wmship.sh resize 0.6           # numeric per-tile check
./wmship.sh resize 1.0
./wmship.sh stop                 # restore byte-exact and verify
```

Leave the machine disarmed and free of debuggers when you finish. One armer at a time: two
concurrent installs invalidate each other.

## Rules that are not negotiable

**Sites and addresses**

- Patch sites are *file* virtual addresses. Runtime = file VA + the target's slide. Resolve them with
  `wmlocate.py` from content and cross-references; never add a constant, never cache a live address.
- The two SkyLight functions live in the dyld shared cache, which is slid per process. Compute their
  live address as the WindowManager's own image base plus the file offset, on every run.

**The payload**

- No `objc_msgSend` from the payload: dispatch is not safe in that context. Use plain C APIs or read
  the WindowManager's own structures.
- The payload has no file I/O. Its control block is one page in the target process, read and written
  over the task port from outside.
- Build the payload as `arm64`, not `arm64e`; authenticated calls cannot work with a raw pointer.
- Objects handed to Swift must be retained exactly once; the target owns its release.

**The strip keeper**

- A resting pose is the smallest pose seen outside a retract. Gate teaching on: strip out
  (`rail_now`, `strip_x >= 0`), no flush window, scale 1.0, and not our own write.
- Never teach the retract pose, and never let a hover-lifted pose become the base: the WindowManager
  restores the resting pose without calling the hook, so a lifted base stays wrong forever.
- Act only on a complete state document: `flush` and `rail_now` must be present and fresh. The
  document is published through a seqlock; read the length, then retry if the generation moves.

**Privilege and distribution**

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
4. Rebuild the payload and run the four capability checks before releasing.

`sites.json` and `profile.json` are the supported-build record. Keep both in the repo.

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Run the **Release** workflow with that version; it refuses a mismatch.
3. The workflow signs with Developer ID, notarizes, staples, publishes the zip and its sha256, and
   opens a PR against the tap with the updated cask.
