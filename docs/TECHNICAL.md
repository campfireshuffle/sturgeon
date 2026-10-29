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
menu-bar app ──► wmship.sh ──► bin/asroot ──► install.py ──► task_for_pid(WindowManager)
                    │              (verbs)        │
                    │                             └─ payload.c  (compiled, copied into the process)
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

### The privileged helper

The only path to root is `bin/asroot`, and it is a **fixed verb dispatcher, not a shell** (#10, #24,
#29). It parses its own `argv`, refuses anything it does not implement, execs `/usr/bin/python3`
with a fixed `PATH` and `HOME`, accepts no stdin, and derives every path from its own real location
(plus the fixed `/tmp/wmship` runtime directory) rather than from `argv` or the environment.

Its verbs:

```
doctor [--json] [--no-live] [--mode pristine|armed|auto]
status [--json]   pristine   install   uninstall   log   counters   probe
selfcheck   teach   daemon-load|arm   daemon-unload|disarm   daemon-status
remove-state   teardown [--keep-state]
move <stage> [--cgid N]   resize <0.4..1.5> [--teach]   level <0|3>   cfg [<json>]
warm | measure | state | poses
```

Arguments are validated by shape before they reach a tool: a scale is numeric and inside 0.4–1.5, a
stage is printable and shell-metacharacter-free, a window id is decimal, a `cfg` document is a JSON
object under 8 KiB. There is no `-c`: the three legacy `-c` shapes the shipped app still sends
(`true`, `install.py status --json`, `install.py cfg '<json>'`) are matched as exact strings and
nothing else in that space is accepted. Adding a capability means adding a verb, not widening an
argument.

`./scripts/selftest.sh` enforces this on the built bundle: it fails on a `-c` passthrough or a
direct `install.py`/`ctl.py` call in the shipped shell scripts, checks that every verb
`wmship.sh` calls exists in `asroot --verbs`, and checks the verbs the Swift app calls directly.

### `doctor`: two modes

`doctor` makes one of two disjoint sets of assertions, and never silently downgrades one to the
other (#6):

- **`pristine`** — nothing of ours is installed. Every site must still hold the on-disk image's own
  bytes, and the object-layout profile must verify against the running process. This is the strict
  mode.
- **`armed`** — `state.json` describes the running WindowManager, and every site holds the stub
  bytes recorded in `backup.json`; each stub lands inside the recorded island; the running body is
  the payload image on disk, with the relocated symbol table masked out of both digests.

`--mode pristine|armed|auto` selects explicitly. `auto` is the default and follows `state.json`'s
pid. An explicit mode the state cannot support is a refusal: asking for `armed` when nothing of
ours is installed fails instead of falling back to `pristine`, because that downgrade would turn
"our patch is inconsistent" into a pass. `doctor` is read-only; `--wm-binary` validates a copy and
can only be pristine.

The daemon's re-apply gate is deliberately the pristine case: it installs only when the running
WindowManager is not the one `state.json` describes (a new pid, after a restart or an OS update),
so auto resolves to `pristine` and the comparison is against the on-disk image. It never validates
— and therefore never arms over — its own live patch.

### Memory the patch owns

The payload is one 16 KB island page taken from a dead page near the patched code and one
anonymous body. Every installed site is one branch away from the island, so the island must be
**executable** before the first site is patched, and the body must be executable where the island
branches into it.

The crash class behind #19 is an **instruction fetch**, not a bad matrix. Both reports had the
program counter equal to the faulting address inside a 16 KB page that was `rw-` with `max rwx`:
writable, not executable. A process cannot produce that state for itself (the kernel denies a
`W|X` mapping), so it came through a task port — our island, in the window between `allocat`, which
leaves it writable, and `prot … rx`. That window is dangerous only while a branch can already
reach the page, which means a second install interleaving with the first, or a partial uninstall
re-allocating the island under a live site. The fixes close the window rather than trusting a
retry:

- `wrmem()` refuses a page that is not already writable, so the helper's fallback (which makes a
  page writable and leaves it that way) is never reached, and every `remap`/`prot` return code is
  checked.
- Before a single live site is patched, the installer runs `island_selftest` on the exact write
  path: write the stubs, set the island `r-x`, read it back byte for byte, and check the live
  protection of the island, the body's code and its data region.
- Each patched site's page is verified `r-x` after it is patched.
- `uninstall` frees nothing until every site is restored and verified: handing back a page that a
  `b` still targets is the same instruction abort.
- An install lock makes two installers refuse each other rather than interleave; the loser would
  otherwise re-allocate the island under the winner's branches.
- The daemon records an unexpected WindowManager exit with the last mutating operation (written to
  `last_op.json` *before* the operation) and stays disarmed. It does not re-arm; a human `doctor`
  or `start` clears the block.

`wmship/selftest.py` proves the guard and reproduces the signature without root and without a task
port: a write or a fetch against a page without the right protection is `SIGBUS` /
`KERN_PROTECTION_FAILURE`, and the guard refuses the page state the crash reports describe.

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
something changes. So the first `resize` after a layout change begins with a **teach pass** — a
pointer sweep across every tile with scaling disabled, which makes the WindowManager emit each
tile's animation in and back out again. The value the return animation settles on is that tile's
resting pose, and it is stored as the base for all later scaling. A single tile costs about a
second: roughly 250 ms of animation in, a dwell, about 300 ms back out, and a settle. That
animation time, not computation, is why a teach pass over a full strip takes a minute or two and
why the pointer moves while it runs. Once the bases are known, `resize` reuses them and does only
a measurement sweep (`resize --teach` or `wmship.sh teach` forces a fresh pass).

**Preflight: `selfcheck`.** Before offering resize, `ctl.py selfcheck` asks whether the teach state
can actually be measured. Measuring at rest cannot answer that: at `s = 1.0` the WindowManager
draws its own resting pose, so `width / natural` reads 1.000 whatever the taught base is. The probe
therefore applies a known scale of **1.2** with teaching off, forces one write-triggering sweep,
and demands every tile read `1.2 × natural` within 2%. A base taught from a hover lift reads
`1.2 × 1.06` and fails. The caller's scale is then restored and measured again, so the check cannot
leave the strip somewhere else. It never teaches. The probe is visible: the strip scales to 1.2 for
a few seconds and back.

`selfcheck` is available as `wmship.sh selfcheck` (and the helper's `selfcheck` verb). On this
build the app's slider is enabled on `armed` alone and does not call it, so the preflight is not yet
wired into the control; treat that wiring as unverified.

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
`rail_now` present), the strip genuinely drawn (tiles in the gutter, a non-flush front window), and
scale 1.0. A strip-transition hold also suppresses teaching. Retract poses are refused
geometrically so a hide can never be mistaken for a rest. When the strip leaves the screen its
bases are discarded. The write being its own is deliberately *not* a gate: after a replay the
resting pose is byte-identical to our own last write, so excluding `ours` made teaching fail
whenever strip-on-top had run first (measured: `learn 0` across a whole teach sweep, `bases 0`,
`resize` a no-op).

**Two poses, not one.** A tile carries a *resting base* (`base`) and a *replay transform* (`rp`).
They are not interchangeable: `base` is the only pose `resize` may scale, and `rp` is what
strip-on-top replays.

- `base` is strict. It is taught only at scale 1.0, while the strip is genuinely drawn (fresh
  document, `rail_x >= 0`, front window not flush) and outside a strip-transition hold, never from
  a retract pose, and never from a pose whose `m0` is smaller than the base already held. It is the
  **largest** first scale entry the tile shows. `m0` is `natural / drawn`, so a hover lift — the
  tile drawn a few percent larger — is the *smaller* value (measured: 1.883 at rest, 1.775
  lifted). Without that rule `resize 1.5` renders `1.5 × lift`; with it, a parked-pointer trial
  moved from 1.607 on the parked tile to 1.493.
- `rp` is looser by design: any write that is not ours and not the identity, while the document
  says the strip is drawn, becomes a candidate. It needs no taught base, which is what makes
  on-top work for a tile that has never been taught: measured 6 of 6 tiles at layer 3 above a
  flush window in three trials with zero bases, and again in three trials with thirteen.

Both are **promoted, not captured**: a candidate becomes the pose only after 0.22 s in which the
WindowManager wrote nothing else for that window, and only while the document still says the strip
is drawn. The margins are measured. The longest gap *inside* one animation is 0.13 s, so a
mid-animation frame is always superseded before the 0.22 s expires; the post-rest silence is at
least 0.3 s or no write follows at all; the document is republished every ~25 ms; and a retract is
~0.3 s of writes, so the last retract frame cannot be both quiet for 0.22 s and still described as
drawn. A per-write rule did follow the retract into the hidden pose (measured: six tiles replayed
at the retracted pose and never came back), which is why promotion exists; `rp` also refuses a
candidate written before the strip last came out.

`base` is dropped when the strip leaves — a base describes the drawing that is on screen now, and
a layout change arrives through a hide — while `rp` survives, because on-top has to redraw across
that hide.

## The app

The menu-bar app is a thin client: every privileged action still goes through the helper and
`wmship.sh`, and the app itself owns no privilege. Three features are new on this build. Their
decision logic is unit-tested; none of their live paths has been exercised against an armed
WindowManager, so they are labelled accordingly below.

**Diagnostics panel.** A disclosure in the popover shows armed state, build and pid, the `doctor`
verdict with its first refusal, the keeper counters, and the last resize as natural → measured →
ratio per tile. The counters come from the helper's `counters` verb (`install.py counters`,
root-only) because `status --json` carries only the aggregate five; if the verb fails the panel
shows the reason instead of dashes. "Copy diagnostics" renders a paste-ready block and redacts home
and temporary paths. *Unit-tested: the block's formatting and redaction. Unverified: live refresh
against a running daemon.*

**Modifier + scroll resize.** An event tap consumes a scroll only while the configured chord is
held and the pointer is inside the strip's rect read from the accessibility tree; every other
scroll passes through. The default chord is **Control + Option** (Option + scroll alone is zoom in
several apps). The value is clamped to 0.4–1.5, snapped to exactly 1.0 within 2%, limited to one
step per 16 ms, and written straight into the payload config (`cfg_gen`) — not through the
sweep-based `resize`. A HUD next to the strip shows the percentage. *Unit-tested: chord matching,
clamp, snap, the accumulator that keeps the snap zone passable, rate limit. Unverified: the tap and
HUD against live WindowManager geometry and input permissions.*

**Drag onto a tile.** The same tap records the window under a mouse press and, on release inside
the strip, re-reads tile frames at release time (the strip animates during the drag) and hit-tests
the release point. Exactly one tile under the point moves the captured window with
`move <stage> --cgid N`. A point outside the strip, the empty gutter, two overlapping tile frames,
or a press on a system-owned window (the strip itself, the Dock) does nothing; ambiguity is counted,
not guessed. Mouse events always pass through, so native drag-out is untouched. *Unit-tested: the
hit-test and its four decisions. Unverified: a live drag onto WindowManager tiles.*

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
| The scale pivot (`16, 490` — a point in the strip gutter) | display size or strip position changes | **quiet**: tiles scale about the wrong point ([multi-display](RESEARCH-multi-display.md)) |
| Fixed settle windows (300–500 ms) | slower or faster animations | **quiet**: teaching reads a mid-animation pose |

The quiet ones are the reason the resize path verifies every tile against a freshly measured natural
size and reports per-tile ratios instead of a single boolean. They are also why the keeper is meant
to publish a decision trace — `m0`, the base value, and the retract/departure/lift verdicts — so a
wrong ratio can be diagnosed without a debugger. That trace is **not in this payload build**:
`payload.c` parses no `trace` key (#31), the app's toggle writes the key but is gated off, and
`wmship.sh` has no trace verb. Until it lands, the evidence is `wmship.sh poses` (the pose table),
`wmship.sh counters`, and the per-tile ratios from `resize`.

The display assumptions are also unmeasured beyond one built-in display; what the code assumes and
the measurements that would replace those assumptions are in
[docs/RESEARCH-multi-display.md](RESEARCH-multi-display.md).

Known weak points, in the order they are worth hardening:

1. **The scale pivot is a constant.** It should be derived from the strip's own geometry each time,
   so a different display or a moved strip cannot scale about the wrong point.
2. **Settle windows are time-based.** Replacing them with "the value has stopped changing" would
   remove the timing assumption entirely.
3. **The resize preflight is not wired into the app.** `selfcheck` can prove the teach state, but
   the slider's `disabled` state is still `armed`/busy alone, so a broken install reaches the
   control that `selfcheck` would have refused.

## Performance

- Window creation to injection: 58–72 ms, no debugger attached. This is the injection cost; the
  end-to-end birth capability did not reproduce on the last attempt (see Verification).
- Per-tile transform replay: the WindowManager's own transaction API, no polling loop in the target.
- The payload contains no timers; it acts only when the patched code runs.
- A resize teach-and-measure pass is dominated by animation time, not work: roughly one second per
  tile, so a full `resize` is a minute or two.
- `selfcheck` costs two short sweeps (probe and restore); the strip is visibly at 1.2 for a few
  seconds.

## Approaches evaluated

| approach | outcome |
|---|---|
| Public window-set API | Model is partial and stale; cannot express assignment |
| Private XPC service | Entitlement-gated; not callable from a third-party process |
| Accessibility actions on tiles | Switch stages; do not assign windows |
| Attaching a debugger | Works, but adds latency to every hit and leaves a debugger resident |
| In-memory payload, read-only outside | Chosen: no debugger, no disk changes, reversible on stop |
| Synthetic gesture input for resize | No supported way to create the magnification event; drive the transform directly instead ([pinch research](RESEARCH-pinch.md)) |
| Deriving the pose from a measured frame | Not viable: the frame is the drawn frame, the translation is not in screen coordinates, and there is no event to calibrate against — teaching stays ([docs/GEOMETRY.md](GEOMETRY.md)) |

## Keeping up with a new macOS build

1. Run `wmship.sh doctor` and read the refusal. It names the site or the missing profile.
2. If the sites resolve but object layout changed, re-derive the profile with `wmship/wmcls` and add
   it to `profile.json` under the new build key.
3. If a site no longer matches, update `wmlocate.py`'s structural signature. Prove it against a
   shifted copy of the binary, and against corrupted copies that must refuse.
4. Re-derive the scale pivot if the strip's geometry changed (see Fragility and
   [multi-display](RESEARCH-multi-display.md)) rather than trusting the constant.
5. Confirm the pose stream still behaves as the keeper assumes. There is no trace yet (#31); use
   `wmship.sh poses` for the pose table and `wmship.sh warm` to make the WindowManager re-emit.
   A hover should produce a burst that returns to a settled value, and a hide should translate
   without changing the scale entry. If either is untrue, the teach pass needs revisiting before
   resize can be trusted.
6. Rebuild the payload, then verify: births, move, strip on top, resize. Numbers, not impressions.

## Verification

Capability checks are numeric and reversible: window layers and per-tile geometry from the window
list, stage membership from the process's accessibility tree, and a byte-exact comparison of every
patched site against the on-disk image after `stop`. Tests avoid synthetic input and never rearrange
the user's stages.

What has actually been exercised, and what has not, on the current tree:

| area | status |
|---|---|
| Site resolution, install/restore, crash guards | exercised without root by `wmship/selftest.py`; bundle invariants by `./scripts/selftest.sh`; install and restore exercised on the owner's machine |
| Strip-on-top | owner-verified: 6/6 tiles at layer 3 above a flush window, three trials with zero taught bases and three with thirteen, still out 2 s later |
| Resize | owner-verified: every tile 1.490–1.500 at 1.5 and 0.600–0.612 at 0.6, exact restore of x/y/w/h |
| Births | implemented, **unverified end-to-end**: the last two attempts injected nothing (`inject=0`) and the window became a strip tile |
| `selfcheck` | logic unit-tested with a fake strip; the visible probe has not been run on this build |
| App diagnostics, gesture resize, drop-to-tile | decision code unit-tested; live paths **not exercised** against an armed WindowManager |
| Pose trace | **absent** from this payload build (#31); the app's toggle is gated off |
