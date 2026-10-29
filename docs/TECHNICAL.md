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
warm | measure | state | poses | trace [--reset]
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
"our patch is inconsistent" into a pass. With `--json`, `doctor` is read-only — that is the shape the
daemon calls, so it can never clear a crash. A human run (no `--json`) clears the daemon's crash
marker on success by unlinking `crash.json`; that is the deliberate way a machine's crash block is
released. `--wm-binary` validates a copy and can only be pristine.

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

**Resize the strip.** The same transaction path carries the tile transforms. Scaling multiplies the
pose's linear part by `1/s` and moves its translation so that one pivot stays fixed (`mat_scale()`).
The keeper composes the current scale onto every pose the WindowManager emits, which catches tiles
that are re-laid out after a stage change.

The pivot is **derived, not a constant.** For every accepted state document the keeper takes the
leftmost drawn **app** tile's `x` and the vertical centre of the drawn app tiles' extent, and uses
that pair for `mat_scale()`. WindowManager's own gutter and overlay windows are excluded because
they move under the pointer. If a document carries no drawn app tile there is no pivot: the scale is
refused, each refused application increments `pivmiss`, the strip stays at its current scale, and
nothing is scaled about a guessed point.
`cfg '{"pivot_fixed":true,"qx":…,"qy":…}'` pins the config pair for a debugging session, and is the
only path by which those config values are used.

The constant this replaced was `(16, 490)`. Measured on the reference display, the fixed point
proved by the tiles themselves (`p = x + (x − x′)/(s − 1)`, with `x` at 1.0 and `x′` at 1.5) is
`x 13–16, y 507–509` for the derived pivot and `x 15–17, y 489–491` for the pinned constant: the
constant was about 18 px off in y. Width ratios cannot see that error — every width was still
right — so the pivot is evidenced by the fixed point, not by the ratios.

Scaling needs a baseline, and the WindowManager never offers one: it emits a transform only when
something changes. So the first `resize` after a layout change begins with a **teach pass** — a
pointer sweep across every tile with scaling disabled, which makes the WindowManager emit each
tile's animation in and back out again. The value the return animation settles on is that tile's
resting pose, and it is stored as the base for all later scaling. A single tile costs about a
second: roughly 250 ms of animation in, a dwell, about 300 ms back out, and a settle. That
animation time, not computation, is why the pointer moves while it runs.

A full teach pass is one sweep over the tiles. If a tile has not settled when the sweep ends,
`wait_bases` supplies a short **wake**: it hovers a tile that already has a base, returns to the
gutter, and waits for the payload's settled flags, with a 2.5 s ceiling. The sweep starts and ends
in the gutter at `x=3`, never inside a tile. A park inside a tile re-hovers it after the last real
visit and leaves its candidate as the sweep's final write; a candidate needs a later keeper call to
be promoted, so that tile would end the pass unsettled. Once the bases are known, `resize` reuses
them and does only a measurement sweep (`resize --teach` or `wmship.sh teach` forces a fresh pass).
A `resize` completes in tens of seconds, not minutes.

A tile that is still unsettled at the end of the pass is reported in `no_base` and left at 1.0; it
does not block the others. `resize` scales the tiles that have a base and reports `no_base`,
`scaled`, `not_scaled` and `partial`, and a non-1.0 scale is never `ok` when a tile was skipped. A
1.0 restore can still be `ok` for a tile that was never moved, but the list is reported in every
case. Only a pass that finds no strip tiles at all refuses the command.

The teach pass also records each tile's resting frame (`x`, `y`, `w`, `h`) at scale 1.0. `resize
1.0` compares the frame it measures against that record and fails a tile that comes back more than
1 px away in x or y, not only one whose width ratio is wrong; the failing ids and deltas are in
`last_resize.json`. The check runs only when the teach pass recorded frames for that strip.

**Preflight: `selfcheck`.** Before offering resize, `ctl.py selfcheck` asks whether the teach state
can actually be measured. Measuring at rest cannot answer that: at `s = 1.0` the WindowManager
draws its own resting pose, so `width / natural` reads 1.000 whatever the taught base is. The probe
therefore applies a known scale of **1.2** with teaching off, forces one write-triggering sweep,
and demands every tile read `1.2 × natural` within 2%. A base taught from a hover lift reads
`1.2 × 1.06` and fails. The caller's scale is then restored and measured again, so the check cannot
leave the strip somewhere else. It never teaches. The probe is visible: the strip scales to 1.2 for
a few seconds and back.

`selfcheck` is available as `wmship.sh selfcheck` (and the helper's `selfcheck` verb). The app runs
it when the popover opens and withholds the size slider until it passes (#35); the pass path on a
live armed install has not been observed, so that gate is implemented and unit-tested but still an
owner check.

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

Both are **promoted, not captured**. A candidate becomes the pose only after **8 state documents**
have arrived with no newer write for that window (`SETTLE_TICKS`), and only while the document still
says the strip is drawn — re-checked at promotion, not only at write time. The tick clock is the
document's own seqlock generation, not wall-clock time and not the payload's call rate: a payload
that was not called for a while still counts the documents it missed, and a loaded machine cannot
shrink the window. A base candidate that a newer write supersedes before it settles — or that reaches
the 3 s TTL — is counted as `unsettled`. The TTL is a wall-clock ceiling so a candidate is not kept
forever.

The margins are measured. The longest gap *inside* one animation is 0.13 s, about 5 documents at the
observer's ~25 ms cadence, so a mid-animation frame is superseded before the 8th document; the
post-rest silence is at least 0.3 s or no write follows at all; and a retract is ~0.3 s of writes, so
`out` closes within a tick or two and the last retract frame cannot also be described as drawn. A
per-write rule did follow the retract into the hidden pose (measured: six tiles replayed at the
retracted pose and never came back), which is why promotion exists; `rp` also refuses a candidate
written before the strip last came out.

`base` is dropped when the strip leaves. It is also dropped when the rail's **app-tile id-set**
changes while the strip is still drawn: closing a window re-lays out the remaining tiles in place,
with no hide, and bases taught against the old drawing are stale. The id-set is the layout's
identity. It is computed over the same app tiles as the pivot (WindowManager's gutter windows
excluded), compared across state documents, and adopted only after two documents agree, so a
one-document membership glitch does not cost a teach pass. A change clears every base and the next
settled write becomes the base again; `rp` is untouched, so on-top survives the change. The event is
counted (`railchg`) and logged with the number of bases dropped.

This addresses the stale-base mechanism, and it is measured. On this build an in-place set change
dropped every base — `bases 14 → 0`, `railchg 0 → 1`, strip and front window unchanged — and after a
tile left the strip, `resize 1.5` scaled every remaining tile (1.490–1.510). The premise that
motivated the issue — that the remaining tiles are drawn *wider* after one leaves — did not
reproduce on this WindowManager build: the rest kept their widths. A stale ratio could therefore not
be induced end to end, and the negative control had nothing to fail on. #4 stays open with this
change as `Refs`, not `Closes`; what is proven is the structural invalidation and the resize after a
real set change, not a reproduction of a 1.575 render.

### The pose trace

`cfg trace=true` (default off) makes the keeper write a record for each decision it takes about a
strip window into a 16 KB ring (`io_tr` in the payload's control page). Read it with `wmship.sh
trace`; `wmship.sh trace --reset` zeroes the ring and its counters. The reader goes through the task
port, sorts records by sequence number, and a record never straddles the end of the ring, so a line
is either whole or absent. `io_tr_len` (bytes ever written) and `io_tr_seq` (records ever written)
are monotonic, so a wrap is distinguishable from a gap.

```
<seq> w= m0= m4= x= y= b0= rw= o= u= b= T= r= a= c= h= q= sm=
```

| field | meaning |
|---|---|
| `<seq>` | record sequence number; the reader sorts by it |
| `w` | window id |
| `m0` | the pose's `m[0]`, its linear scale entry (`natural / drawn`; a hover lift is smaller) |
| `m4` | the pose's `m[4]`, the next linear entry, so a rotation or shear is visible beside `m0` |
| `x`, `y` | the pose's `m[12]`, `m[13]`; translation in the pose's own space, not screen coordinates |
| `b0` | the held base's `m0`, or `-1` when the tile has no base |
| `rw` | the drawn width the document reports, or `-1` when the tile is not in the rail |
| `o` | 1 when the document says the strip is genuinely drawn |
| `u` | 1 when this write is our own |
| `b` | 1 when the tile has a base |
| `T` | 1 when the write was eligible to become a base candidate: scale 1.0, not identity, strip drawn, outside a hold, not a retract |
| `r` | 1 when the write is a retract pose |
| `a` | 1 when the window is not in `rail_now` (in the strip but not drawn) |
| `c` | 1 when a base candidate is being held |
| `h` | milliseconds left in the current hold, 0 outside one |
| `q` | documents elapsed since the held candidate's last write, 0 when none is held |
| `sm` | the scale in effect when the decision was made |

It is **write-only by construction**: no branch in `payload.c` reads `io_tr`, and `wmship/selftest.py`
asserts that. Turning it on cannot change a keeper decision. Use it when a width ratio is wrong,
when `resize` reports a tile in `no_base`, or when the strip retracts during a sweep: the record
shows which gate refused the write (`T`, `r`, `o`, `a`, `h`) and how far a candidate got (`c`, `q`).
Measured: one hover sweep produced 143 records, the largest 113 bytes; with the key back off, the
same sweep produced no new records and the next teach's decisions were unchanged (`bases 14 → 14`).

The menu-bar app's **Pose trace** toggle writes the `trace` key. **Show trace** runs `wmship.sh
trace` and shows the last 40 records with this legend. The read has three states: records,
`unavailable` (the command succeeded but the ring returned nothing — an older payload without the
trace ring, or no keeper decision yet), and `failed` (the refusal line). An older payload therefore
shows `unavailable`, not an empty table. The toggle is disabled while disarmed, and turning the
trace off drops the last read.

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
strip geometry, each drawn rail tile's frame, which windows are in the rail, the front window, and
the current phase. The document is written under a seqlock; readers take the generation, copy, and
retry if it moved. Readers also check that the document is complete — a prefix that happens to
parse is rejected, because acting on a partial document is how a keeper ends up scaling the wrong
thing.

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
| Pivot derivation from the rail's drawn app-tile frames | a document with no drawn app tile | **loud**: the scale is refused and counted (`pivmiss`); `resize` to a non-1.0 scale fails its ratio check instead of scaling about a guessed point |
| Transition holds (0.30–0.50 s) around a reveal, retract or departure | slower or faster animations | **loud**: a tile can be named in `no_base` and left at 1.0 while the others scale; a non-1.0 `resize` reports `partial` and never `ok`. Promotion is document-ticked, so a mid-animation frame is not promoted |

The quiet ones are the reason the resize path verifies every tile against a freshly measured natural
size, reports per-tile ratios, and checks x/y restoration at 1.0. They are also why the keeper
publishes a decision trace: `cfg trace=true` records `m0`, the held base, and the
drawn/ours/teach/retract verdicts into the ring that `wmship.sh trace` reads. The ring is
write-only, so a diagnosis cannot change the decisions it observes.

Display assumptions are still unexercised beyond one built-in display. The pivot is now derived from
the document rather than from a display constant, but the study in
[docs/RESEARCH-multi-display.md](RESEARCH-multi-display.md) predates that change; what remains
unmeasured is listed there.

Known weak points, in the order they are worth hardening:

1. **The transition holds are still wall-clock.** `hold_until` (0.30–0.50 s) suppresses candidate
   capture around a reveal, retract or departure. They are a safety net, not the promotion rule:
   promotion counts documents with no newer write, so a slower animation delays a teach instead of
   promoting a mid-burst frame. The holds are the only remaining wall-clock gate on *what may become
   a candidate*.
2. **The resize preflight is a measurement, not a repair.** `selfcheck` applies a 1.2 probe with
   teaching off, requires every tile within 2%, then restores the caller's scale. The app runs it
   when the popover opens and withholds the size slider until it passes (#35); the pass path on a
   live armed install still needs owner verification. It cannot fix a wrong base — only
   `wmship.sh teach` re-learns the bases.

## Performance

- Window creation to injection: 58–72 ms, no debugger attached. This is the injection cost; the
  end-to-end birth capability did not reproduce on the last attempt (see Verification).
- Per-tile transform replay: the WindowManager's own transaction API, no polling loop in the target.
- The payload contains no timers; it acts only when the patched code runs.
- A `resize` that has to teach pays one pointer sweep over the tiles, plus a short wake (2.5 s
  ceiling) only when a tile has not settled; later calls reuse the bases and pay only the
  measurement sweeps. A complete `resize` finishes in tens of seconds, not minutes.
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
4. Confirm the pivot still derives. After a document with drawn app tiles, `hb.psrc` should be 1,
   `hb.px`/`hb.py` should sit at the rail's left edge and vertical centre, and `hb.pivmiss` should
   stay 0 across a resize. If `psrc` is 0, scaling is being refused by design: fix the document or
   the derivation, not by pinning the old constant.
5. Confirm the pose stream still behaves as the keeper assumes. Turn on `cfg trace=true`, run a
   sweep, and read `wmship.sh trace`: a hover should produce a burst that returns to a settled value
   (the `T=1` records are the teach-legal candidates; `b`/`b0` show the base held), and a hide
   should translate without changing `m0` (`r=1` marks the retract frames). Turn it off afterwards.
   `wmship.sh poses` remains the pose table and `wmship.sh warm` makes the WindowManager re-emit.
   If either shape is untrue, the teach pass needs revisiting before resize can be trusted.
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
| Strip-on-top | owner-verified: 6/6 tiles at layer 3 above a flush window, three trials with zero taught bases and three with thirteen, still out 2 s later. Re-measurement was partial: the replay/raise path ran and the one tile composited in a full-screen Space measured layer 3, but 6/6 could not be re-measured (the Space composited only that tile; a same-Space flush was reverted by the window manager) |
| Resize | owner-verified: every tile 1.490–1.500 at 1.5 and 0.600–0.612 at 0.6, exact restore of x/y/w/h; the derived pivot proved from the frames at x 13–16, y 507–509 against the pinned constant's y 489–491, and `resize 1.0`'s x/y check passed on seven tiles |
| Stale bases (#4) | mechanism owner-verified: an in-place rail id-set change dropped every base (`bases 14 → 0`, `railchg 0 → 1`) and a following `resize 1.5` scaled every remaining tile (1.490–1.510). The "remaining tiles are drawn wider" premise did not reproduce on this WindowManager build, so the issue stays open with `Refs`, not `Closes` |
| Births | implemented, **unverified end-to-end**: the last two attempts injected nothing (`inject=0`) and the window became a strip tile |
| `selfcheck` | logic and app gate unit-tested (#35); the pass path on a live armed install has not been observed — owner check |
| App diagnostics, gesture resize, drop-to-tile | decision code unit-tested; live paths **not exercised** against an armed WindowManager |
| Pose trace | **present**; owner-verified: one hover sweep wrote 143 records, largest 113 bytes; with `trace=false` no new records appeared and the next teach's decisions were unchanged (`bases 14 → 14`). Write-only, asserted by `wmship/selftest.py`. The app's **Pose trace** toggle writes `trace`; **Show trace** reads the ring and shows the last 40 records, or `unavailable` on an older payload |
