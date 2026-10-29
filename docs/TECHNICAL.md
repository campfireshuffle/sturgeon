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
- **The daemon** re-applies the patch after an OS update. It runs the full doctor check before
  every attempt and stays disarmed, with a logged reason, if the check refuses. A `WindowManager`
  that *disappears while armed* is different: the daemon records a crash — the pid it was armed on,
  the pid that replaced it (or none), and the last mutating operation the tool performed, which
  `install.py` writes to `/tmp/wmship/last_op.json` *before* each operation — and then stays down.
  It does not re-arm: a machine cannot decide on its own that a process which died under the patch
  is safe to patch again. A human `doctor` (or `start`) clears the block.

### Memory the patch owns

The payload is one 16 KB island page taken from a dead page near the patched code and one
anonymous body. Every site we install is one branch away from the island, so the island must be
**executable** before the first site is patched, and the body must be executable where the island
branches into it. The installer therefore runs a self-test on the exact write path before it
touches a live site: write the stubs, set the page `r-x`, read it back byte for byte, and check the
live protection of the island, the body's code and its data region. Anything else is a named
refusal. `wrmem()` refuses to write a page that is not already writable, so the helper's own
fallback (which makes a page writable and leaves it that way) is never reached; every `remap` and
`prot` return code is checked; each patched site's page is verified `r-x` after it is patched; and
`uninstall` frees nothing until every site has been restored and verified, because handing the
island back while a `b` still points into it is an instruction abort inside `WindowManager`, not a
tool error. `wmship/selftest.py` proves the guard and reproduces the fault signature (a write or a
fetch against a page without the right protection is `SIGBUS`/`KERN_PROTECTION_FAILURE`) without
root and without a task port. One install at a time is enforced with a lock: two concurrent
installs invalidate each other, and the way they do it is that same instruction abort.

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

Scaling needs a baseline, and the WindowManager never offers one: it emits a transform only when
something changes. So `resize` begins with a **teach pass** — a pointer sweep across every tile with
scaling disabled, which makes the WindowManager emit each tile's animation in and back out again. The
value the return animation settles on is that tile's resting pose, and it is stored as the base for
all later scaling. A single tile costs about a second: roughly 250 ms of animation in, a dwell, about
300 ms back out, and a settle. Seven tiles, two passes, one teach pass and a verification pass is why
one `resize` invocation takes a minute or two, and why the pointer moves while it runs. It is waiting
for animations to finish, not computing.

### The strip keeper

The hard part is knowing what to scale. A tile's pose arrives as a 4x4 matrix whose first entry
carries the linear scale. The WindowManager draws three kinds of pose: the *resting* pose, an
*animated* pose while the pointer is over a tile (the tile is drawn a few percent larger, so the
scale entry moves away from the resting value frame by frame), and a *retract* pose when the strip
hides, which is a translation only.

Only the resting pose is a valid base. A base taken from the middle of the hover animation bakes
that magnification into every later scale — the error is a few percent and looks like a scaling bug
rather than a teaching bug.

The keeper therefore waits for the end of an animation burst and keeps the value the pose settles
on, and it gates teaching on three conditions: a complete and fresh state document (`flush` and
`rail_now` present), the strip actually on screen, and scale at 1.0. Retract poses are refused
geometrically so a hide can never be mistaken for a rest. When the strip leaves the screen its
bases are discarded. The write being its own is deliberately *not* a gate: after a replay the
resting pose is byte-identical to our own last write, so excluding `ours` made teaching fail
whenever strip-on-top had run first (measured: `learn 0` across a whole teach sweep, `bases 0`,
`resize` a no-op).

**Two poses, not one.** A tile carries a *resting base* and a *replay transform*, because the two
capabilities want opposite things from a pose and coupling them made one regress whenever the other
was fixed. The base is strict — it is the pose the WindowManager wrote and then stopped writing,
which is the only thing that may be scaled. The replay transform only has to keep the tile drawn,
so it is taught from looser candidates (any settled write while the strip is on screen, at any
scale) and it is what strip-on-top puts back. On-top therefore works for a tile that has never been
taught a resting base, which is what a tightened teach gate used to break: measured 6/6 tiles at
layer 3 above a flush window in three trials with `bases 0`, and again 6/6 in three trials with
thirteen bases. Both are *promoted* after 0.22 s of silence rather than captured per write — a
retract is a run of animation frames that would otherwise be followed into the hidden pose.

Two invariants matter when touching this code. Poses are stored as raw bytes, so comparisons must
cast to `double` before reading the scale entry; comparing the byte array directly compares one
mantissa byte and silently produces plausible-looking decisions. And a pose's translation and its
scale change independently: a hide moves the tile without changing its scale, so "the pose moved" is
not evidence of a relayout.

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

## Fragility

Every capability is inferred from observed behaviour, so each one rests on an assumption that a
future macOS can invalidate. What matters is whether a break is loud or quiet.

| dependency | if it changes | failure mode |
|---|---|---|
| Six patch sites, located by content and cross-reference | locator cannot identify a site | **loud**: named refusal, nothing is written |
| Per-build object layout (`WindowID` class and ivar offsets) | unknown build | **loud**: doctor refuses before arming |
| Root, SIP off, `task_for_pid` | SIP enabled | **loud**: the tool will not arm |
| SkyLight transform and level calls | private API changes | **quiet**: strip-on-top and resize stop applying |
| Tiles emit transforms on pointer movement | emission changes | **quiet**: sweeps produce nothing, resize does nothing |
| Hover animation shape (burst length, settle value) | timing or easing changes | **quiet**: bases are wrong by a few percent |
| The scale pivot (`16, 490` — a point in the strip gutter) | display size or strip position changes | **quiet**: tiles scale about the wrong point |
| Fixed settle windows (300–500 ms) | slower or faster animations | **quiet**: teaching reads a mid-animation pose |

The quiet ones are the reason the resize path verifies every tile against a freshly measured natural
size and reports per-tile ratios instead of a single boolean. They are also the reason the keeper
keeps a trace: with `cfg trace=true` the payload publishes each decision (`m0`, base value, and the
retract/departure/lift verdicts), so a wrong ratio can be diagnosed without a debugger.

Known weak points, in the order they are worth hardening:

1. **The scale pivot is a constant.** It should be derived from the strip's own geometry each time,
   so a different display or a moved strip cannot scale about the wrong point.
2. **Settle windows are time-based.** Replacing them with "the value has stopped changing" would
   remove the timing assumption entirely.
3. **No preflight for resize.** A single-tile sweep that measures one ratio and reports it would turn
   a quiet mis-measure into a refusal before the UI offers the control.

## Performance

- Window creation to injection: 58–72 ms, no debugger attached.
- Per-tile transform replay: the WindowManager's own transaction API, no polling loop in the target.
- The payload contains no timers; it acts only when the patched code runs.
- A resize teach-and-measure pass is dominated by animation time, not work: roughly one second per
  tile, so a full `resize` is a minute or two.

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
4. Re-derive the scale pivot if the strip's geometry changed (see Fragility) rather than trusting the
   constant.
5. Confirm the pose stream still behaves as the keeper assumes: with `cfg trace=true`, a hover should
   produce a burst that returns to a settled value, and a hide should translate without changing the
   scale entry. If either is untrue, the teach pass needs revisiting before resize can be trusted.
6. Rebuild the payload, then verify: births, move, strip on top, resize. Numbers, not impressions.

## Verification

Capability checks are numeric and reversible: window layers and per-tile geometry from the window
list, stage membership from the process's accessibility tree, and a byte-exact comparison of every
patched site against the on-disk image after `stop`. Tests avoid synthetic input and never rearrange
the user's stages.
