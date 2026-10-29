# Technical notes

This document describes how Sturgeon works, the constraints it operates under, and how to keep it
working across macOS releases.

## The constraint

Stage Manager is implemented by `WindowManager`, a system process. The four capabilities Sturgeon
provides all require changing how that process assigns and draws windows. There is no supported
interface for any of them:

- The window-set model is read-only from outside. The only published representation
  (`CGSCopyManagedDisplaySpaces().windowSets`) is partial and stale; the authoritative model is the
  process's own object graph, reachable through its accessibility tree.
- The private XPC service that would accept window-set operations is gated behind an Apple
  entitlement, so it cannot be called by any third-party process.
- Accessibility actions on strip tiles switch stages; they do not assign a window to a set.

Sturgeon therefore patches `WindowManager` in memory: a small position-independent payload is
allocated inside the process, six sites in its code are redirected to it, and the process continues
running normally. Nothing is written to disk, and the patch is removed on `stop` or on any restart of
the process.

This requires root and System Integrity Protection to be disabled. Those are prerequisites, not
bypasses: with SIP enabled, `task_for_pid` against a platform binary is refused by the kernel.

## Architecture

```
menu-bar app ──► wmship.sh ──► install.py ──► task_for_pid(WindowManager)
                    │             │
                    │             └─ payload.c  (compiled, copied into the process)
                    │
                    ├─ ctl.py      capability commands over the payload's control page
                    └─ wmlocate.py resolves the six sites from binary content
```

- **Site resolution** is content-based. `wmlocate.py` finds the two call sites that reach the
  instantiation driver, the driver entry itself, its compute callee, and the two SkyLight transform
  functions. Each candidate is validated against instruction class, caller/callee relationships and
  the target argument registers. Results are cached per build (`<CFBundleVersion>|<sha256 of __TEXT>`)
  in `sites.json`.
- **The payload** is built as plain `arm64` and copied into an anonymous executable region close
  enough to the patched sites for a direct branch. It contains no file I/O and no Objective-C
  dispatch; all communication happens through a page that the tool reads and writes over the task
  port.
- **The daemon** re-applies the patch after `WindowManager` restarts or after an OS update. It runs
  the full doctor check before every attempt and stays disarmed, with a logged reason, if the check
  refuses.

## Capabilities

**New windows join the current stage.** The instantiation driver is called once per element while a
window is being adopted. Sturgeon substitutes a one-element operation that targets the current
stage's window set. The newborn is identified from the process's own serial-to-window-ID table, so no
Objective-C introspection is involved. Measured cost from window creation to injection: 58–72 ms.

**Move a window between stages.** The same operation type is submitted for an existing window, which
moves it to the chosen set. The observable change is verified through the process's accessibility
tree, not through the stale public model.

**Keep the strip on top.** The WindowManager draws the strip through its own transaction API.
Sturgeon replays each tile's transform and level through that API when a window is drawn over the
strip's gutter, and keeps replaying while it stays covered. Measured with seven tiles above a
full-width window: all seven remained visible at level 3 across every sample, with controls flat.

**Resize the strip.** The same transaction path carries the tile transforms. Scaling is applied to
each tile's resting transform, so tiles scale about their own geometry. The keeper composes the
current scale onto every pose the WindowManager emits, which catches tiles that are re-laid out after
a stage change.

### The strip keeper

The hard part is knowing what to scale. A tile's pose arrives as a 4x4 matrix. The WindowManager
writes a *resting* pose, a *lifted* pose while the pointer is over a tile, and a *retract* pose when
the strip hides. The resting pose is the only correct base; the lifted pose is about 5.5% larger and
is restored by the WindowManager from its own copy without calling the hook, so a lifted base would
persist and scale every later transform by 1.055.

The keeper therefore treats the **smallest pose seen outside a retract** as the base, gates teaching
on a complete, fresh state document (`flush`, `rail_now`, strip on screen, scale 1.0, not our own
write), and discards bases when the strip leaves the screen.

## State channel

The payload cannot read files, so the tool publishes a small JSON document into its control page:
strip geometry, which windows are in the rail, the front window, and the current phase. The document
is written under a seqlock; readers take the generation, copy, and retry if it moved. Readers also
check that the document is complete — a prefix that happens to parse is rejected, because acting on a
partial document is how a keeper ends up scaling the wrong thing.

## Durability across builds

Addresses move whenever `WindowManager` or the dyld shared cache is rebuilt. Three things keep that
manageable:

1. **No constant addresses.** Every site is derived from content and cross-references at install
   time, and every candidate must pass structural checks. An ambiguous or missing site is a refusal
   with a named reason.
2. **Per-build data, kept in the repository.** Object-layout metadata lives in `profile.json`, keyed
   by build; site results live in `sites.json`, keyed by build and text hash. A known build is
   instant; an unknown one goes through the scan.
3. **Per-process slides.** The WindowManager's own slide is read from the target process. The two
   SkyLight functions live in the shared cache, which is slid independently per process on current
   macOS, so their live addresses are computed as the target's image base plus the file offset — never
   from a helper process's `dlsym`.

If any of this cannot be established with confidence, the tool refuses to install and says which
check failed.

## Performance

- Window creation to injection: 58–72 ms, no debugger attached.
- Per-tile transform replay: the WindowManager's own transaction API, no polling loop in the target.
- The payload contains no timers; it acts only when the patched code runs.

## Approaches evaluated

| approach | outcome |
|---|---|
| Public window-set API | Model is partial and stale; cannot express assignment |
| Private XPC service | Entitlement-gated; not callable from a third-party process |
| Accessibility actions on tiles | Switch stages; do not assign windows |
| Attaching a debugger | Works, but adds latency to every hit and leaves a debugger resident |
| In-memory payload, read-only outside | Chosen: no debugger, no disk changes, reversible on stop |
| Synthetic gesture input for resize | No supported way to create the magnification event; drive the transform directly instead |

## Keeping up with a new macOS build

1. Run `wmship.sh doctor` and read the refusal. It names the site or the missing profile.
2. If the sites resolve but object layout changed, re-derive the profile with `wmship/wmcls` and add
   it to `profile.json` under the new build key.
3. If a site no longer matches, update `wmlocate.py`'s structural signature. Prove it against a
   shifted copy of the binary, and against corrupted copies that must refuse.
4. Rebuild the payload, then verify: births, move, strip on top, resize. Numbers, not impressions.

## Verification

Capability checks are numeric and reversible: window layers and per-tile geometry from the window
list, stage membership from the process's accessibility tree, and a byte-exact comparison of every
patched site against the on-disk image after `stop`. Tests avoid synthetic input and never rearrange
the user's stages.
