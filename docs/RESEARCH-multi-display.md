# Research: multi-display and multi-Space behaviour

Status: **unmeasured**. Every geometry figure in `docs/TECHNICAL.md` was measured on a single built-in
display whose point space is 1512×982. No second display was attached while this note was written, and no
virtual display was used, so nothing below describes observed multi-display behaviour. What follows is
what the code assumes today, the measurements a person has to take to replace those assumptions with
facts, and the shape of the change if the answer turns out to be "the tiles are per display".

## 1. The coordinate space everything is written in

`CGWindowListCopyWindowInfo`, `CGDisplayBounds` and the WindowManager's accessibility frames all report
in one global display space. Its origin is the top-left of the main display. A display arranged to the
right of the main one starts at positive x, one arranged above or to the left has negative y or x.
Nothing in the code converts between displays, because nothing in the code knows there is more than one:
there is no call to `CGGetActiveDisplayList`, `NSScreen.screens` or any CGS display API anywhere in
`Sources/`, `wmship/`, `wm/`, `helpers/` or `a/`.

The consequence is that every strip test in the shipped path is an x-interval test on the main display's
left edge. That is exact for one display and meaningless for a second one.

## 2. What the code assumes today

| # | assumption | where it is encoded |
|---|---|---|
| 1 | There is one strip, at the left edge of the main display. | `rail_rect_x()` and the `out` gate in `wmship/payload.c`; the rail tests in `helpers/r21obs.swift` |
| 2 | A strip tile is a window at the top-left of the main display. | the rail tests in `helpers/r21obs.swift`, `measure()` in `wm/wmctl.py` |
| 3 | A window is *in the rail* only when `minX >= 0`. Windows parked at negative x are excluded on purpose. | `helpers/r21obs.swift` (`rail_now`) |
| 4 | The strip is out when at least two qualifying windows are on screen. | `strip_on` in `helpers/r21obs.swift` |
| 5 | A full-size window is frontmost when its `minX <= 2` and its width ≥ 1200 points. | `flush` in `helpers/r21obs.swift` |
| 6 | The front window is the first non-system window in front-to-back order that is at least 600×300, at layer 0 (layer 0 or 3 in `wmctl`'s `measure()`), on any display. | `helpers/r21obs.swift`, `wm/wmctl.py` `measure()` |
| 7 | Scaling uses one screen pivot, `(16, 490)`, for every tile of every strip. | `G.qx`/`G.qy` defaults in `wmship/payload.c`; written as constants by `wmship/ctl.py` and `wmship/install.py` |
| 8 | One scale factor applies to every tile. | `G.s`, `mat_scale()` |
| 9 | The strip retracts by about 287 points (the gutter constant 286.92) and a write 80 points to the left of the taught base is the hidden pose. | `is_retract()` in `wmship/payload.c` |
| 10 | At most 32 rail ids and 48 poses are needed. | `MAXIDS`, `MAXP` in `wmship/payload.c` |
| 11 | One state document, one generation, 16 KB, describes the whole system. | `publish_st()` in `wmship/wmhb.c` |
| 12 | The stage model is one `sm.space` group containing one `sm.strip` list, and stages are that list's buttons. | `WM.stages()` and `stripElement()` in `a/stagepilot.swift` |
| 13 | The gutter is 285 points and the strip is revealed by hovering at the main screen's mid-height. | `gutter()`, `revealStrip()` in `a/stagepilot.swift` |

Assumption 3 is the load-bearing one. `rail_now` is the array the keeper repairs poses from, and its
membership test is `f.minX >= 0` plus an upper bound of 300. A strip on a display arranged to the left
has negative x and can never be in it. A strip on a display arranged to the right has x ≥ the main
display's width and can never be in it either. The document therefore cannot describe a strip anywhere
except the main display's left edge, whatever the WindowManager actually draws.

The exact tests behind assumptions 2 and 3 differ, and all three are worth quoting because a
measurement has to say which one disagreed:

| test | condition on a window |
|---|---|
| `rail` (`r21obs`) | `minX > -420`, `maxX <= 320`, 8 ≤ width ≤ 320, height ≤ 520 |
| `rail_now` (`r21obs`) | `minX >= 0`, `maxX <= 300`, 8 ≤ width ≤ 300, 8 ≤ height ≤ 560 |
| `measure()` (`wmctl`) | `0 <= x < 320`, 8 ≤ width ≤ 330, 8 ≤ height ≤ 560 |

`rail_now` has no y bound and no owner requirement beyond the skip list, so it is also the test most
likely to accept an unrelated window that happens to sit in the top-left corner.

Assumption 5 is the second one worth stating plainly: a display narrower than 1200 points in its scaled
mode can never report `flush`, so the strip-on-top replay and the teach gate would never be entered on
that display. `MINW` defaults to 1200 and `wmship.sh` does not override it.

Assumption 12 is where Spaces enter, and they enter only indirectly. The stage model is one window set
per Space, but no code reads a Space identifier: stages are addressed through the WindowManager's own
window-set objects, and the public `CGSCopyManagedDisplaySpaces` model is deliberately not used because
it is partial and stale. To this code, a window moved to another Space is simply a window that is no
longer in the current stage's set and no longer in the rail. Whether the pose table then drops it or
keeps replaying a pose for a window that is not on screen is unverified; §3.5 asks for it.

The state document is the only channel between the observer and the payload, and its shape is fixed:

| field | meaning on one display | what it would mean with two |
|---|---|---|
| `rail` | windows the strip has shown in the last 10 s, with their current frames (`x, y, w, h, on`) | would need a display or group key, or it mixes two strips |
| `rail_now` | ids of windows drawn inside the gutter right now | the same, per strip |
| `strip_on` | at least two such windows are on screen | one boolean for two strips |
| `front_x` | `minX` of the frontmost large window | ambiguous: a large window on either display |
| `flush` | that window is flush to x = 0 and ≥ 1200 wide | only ever true on the main display |
| `strip_ids` | union of rail ids over the last 10 s | union over both strips |
| `t` | observation time | unchanged |

The payload mirrors what it received into its heartbeat: `stx` (min x over `rail_now`), `fx`, `ston`,
`strail`, `stflush`, `stok`, `stgood`, `stbad`, `stbusy`, `stlen`, `stms`. Those are the fields a
measurement has to quote, because they show what the keeper actually acted on rather than what the
observer wrote.

## 3. Measurements to take on a second display

The state document only exists while the patch is installed, so this procedure requires arming. That is
the payload stream's job, under its lock and its one-arm-at-a-time rule; it must not be run by any other
stream. The configuration survey and the accessibility dump below need no patch and can be done by
anyone.

Record the machine state first, because every result is only meaningful against a configuration.

```sh
sw_vers
system_profiler SPDisplaysDataType        # resolutions, main display, mirroring
```

For each display note: point size (not pixels), origin in the arrangement, scaled mode, whether it is
main, and whether "Displays have separate Spaces" is on. Then, armed:

```sh
./wmship.sh status                        # armed, capabilities, processes
wmship/ctl.py state                       # the document as the payload received it
wmship/ctl.py measure                     # tiles, live ids, helper counters
wmship/ctl.py poses                       # per window: base taught? own write? level?
wmship/ctl.py cfg                         # s, qx, qy, enabled keys
cat /tmp/wm/state.json                    # the observer's own document, before the copy
```

There are three layers and they disagree in useful ways: the observer's file (`/tmp/wm/state.json`), the
copy in the payload page (`ctl.py state`, which reports length, generation and completeness), and the
payload's gate values (`ctl.py measure` → `hb`, and `wmship.sh status`). A measurement that quotes only
one of them cannot distinguish "the observer never saw the strip" from "the payload rejected the
document" from "the keeper decided not to act".

### 3.1 Configuration and geometry

1. Reveal the strip by hovering at the left edge of each display in turn. Record whether a strip appears
   on the second display at all, and its frame.
2. Dump the WindowManager's accessibility tree once per configuration. Today the tree exposes a single
   `sm.space` group with one `sm.strip` child; record whether a second group or a second strip child
   appears, and each one's frame. `bin/stagepilot stages` prints stage frames and window ids from that
   tree.
3. Record the strip's on-screen bounds from the window list: every tile's `x, y, w, h` and owner, plus
   the WindowManager's blocker windows that pair with each tile. Compare against §2 assumption 9: the
   gutter width on the second display is the number that would replace 286.92.

### 3.2 What the state document reports

For each configuration, with the strip revealed on the second display:

| to record | where |
|---|---|
| `rail` entries: ids, `x`, `y`, `w`, `h`, `on` | `/tmp/wm/state.json` |
| `rail_now`: ids, and whether any belong to the second display's strip | `/tmp/wm/state.json` |
| `strip_on` | both documents |
| `front_x` and `flush` with a full-size window on each display | both documents |
| `stx`, `fx`, `ston`, `strail`, `stflush`, `stok` | `ctl.py measure` → `hb` |
| document length, generation, completeness | `ctl.py state` |

The specific question is whether `rail_now` stays empty while a strip is visibly out on the second
display, and whether `strip_on` stays false. If both, the keeper is blind to that strip and nothing
scales or stays on top there. If `rail_now` picks up second-display tiles, check whether it also picks
up unrelated windows that happen to satisfy the x-interval test on the main display, because the test
has no y bound and no owner requirement beyond the skip list.

### 3.3 Whether tiles are per display

Three independent checks, because they can disagree:

- **Model.** Does the accessibility tree expose one strip per display or one strip that follows the
  focused display? Compare each stage button's `AXWindowsIDs` with the tile ids seen on each display.
- **Observation.** Do the second display's tiles appear in `rail`/`rail_now` with their own ids, or is
  the document still describing the main display's tiles?
- **Behaviour.** With Stage Manager showing a strip on each display, click a tile on the second display.
  Does the stage switch on that display only, on both, or not at all? This is the question that decides
  whether "the stage model is one set per display" is true.

### 3.4 A resolution change while armed

Change the scaled mode of one display, then, without restarting anything:

1. Whether the strip re-lays out and whether the keeper re-teaches bases (watch `bases` and `learn`
   counters in `hb`, and `ctl.py poses`).
2. Whether the scale still lands: `wmship.sh resize <s>` reports a ratio per tile against each tile's
   recorded natural width. A ratio far from `s` on the changed display, with correct ratios elsewhere,
   is a pivot or base problem confined to that display.
3. Whether the verification itself is trustworthy. `apply_scale()` keeps its natural-width record keyed
   by window id and refreshes it only when the *set* of ids changes. A resolution change that keeps the
   same tiles does not refresh the record, so the reported ratio can be wrong in either direction. Treat
   the first post-change ratio as suspect and re-run `resize 1.0` first.
4. Where the tiles drift. If scaling is applied about `(16, 490)` on a display whose strip is elsewhere,
   the error is a translation proportional to `(1 - 1/s)` times the distance from that pivot. Recording
   tile positions at `s = 1.0`, `1.2` and `1.5` gives the pivot back by fitting: the point that does not
   move is the pivot actually in use.

### 3.5 Spaces, and Stage Manager off/on

The document carries no Space identity at all. With "Displays have separate Spaces" on, move a window
between Spaces and record whether `rail`, `strip_ids` or the pose table change, and whether the keeper
touches a window that belongs to a Space that is not on screen. Do the same with Stage Manager switched
off and on while armed: the strip disappears and returns, which is the case the teach gate is designed
for, but only on one display has it been tested.

## 4. Test matrix

Rows are configurations. Columns are the checks. Fill each cell with the observed value or `✓` / `✗` /
`?`, and keep the raw documents alongside.

| config | strip on 2nd display | `rail_now` sees it | one strip or per display | tile click switches | `flush` fires | resize ratio per tile | on-top holds | document complete | notes |
|---|---|---|---|---|---|---|---|---|---|
| one display, 1512×982 (baseline) | n/a | – | one | – | – | – | – | – | already measured |
| + external, arranged right | | | | | | | | | |
| + external, arranged left | | | | | | | | | |
| + external, arranged above | | | | | | | | | |
| + external, arranged below | | | | | | | | | |
| external only (clamshell) | | | | | | | | | |
| external as main display | | | | | | | | | |
| mirrored pair | | | | | | | | | |
| display added while armed | | | | | | | | | |
| display removed while armed | | | | | | | | | |
| scaled mode changed while armed | | | | | | | | | |
| two Spaces, window moved between | | | | | | | | | |
| Stage Manager off then on while armed | | | | | | | | | |

`n/a` and `–` mean the question does not arise; blank means not yet measured. A row is only complete
when the observer document, the payload's copy and the payload's gate values were all recorded for it.

## 5. What the code would need if the tiles are per display

This is a design sketch, not a plan. It follows from the shape of the current code, and every step
assumes the measurement above first shows that the second display really does carry its own strip.

**State document.** Add a display table and a display key per window:

```json
{ "displays": [ {"id": 1, "main": true,  "bounds": {"x": 0,    "y": 0, "w": 1512, "h": 982}},
                {"id": 2, "main": false, "bounds": {"x": 1512, "y": 0, "w": 1920, "h": 1080}} ],
  "rail": [ {"id": 964, "d": 1, "x": 16, "y": 205, "w": 60, "h": 97, "on": 1}, ... ] }
```

`strip_on`, `rail_x`, `front_x` and `flush` become per-display values (a map keyed by display id) rather
than scalars. The rail membership test becomes "inside the gutter of display `d`", derived from that
display's bounds, instead of `minX >= 0 && maxX <= 300`. The 16 KB copy and its truncation warning have
to be re-sized for two documents' worth of rail entries; `MAXIDS` (32) and `MAXP` (48) need the same
look, since two strips of ten tiles plus their blocker windows approach or exceed 48 poses.

**Pose table.** The table is already keyed by window id, and window ids are global, so the table itself
survives. What does not survive is the single pivot. Each pose needs either a display id plus a
per-display pivot, or its own pivot stored at teach time.

**Pivot from geometry.** Today's pivot is the strip's left edge and vertical centre in the display's
point space. That is the right kind of quantity to derive, but it cannot be read out of the transform:
the written matrix's translation row is a coefficient of the inverse pose, not a screen coordinate, and
the code records the failure of a gate built on `m[12] >= 0`. Derive the pivot from observed tile frames
instead: per strip group, take the group's left edge and its vertical centre from the `rail` entries,
then confirm it with the fixed-point test in §3.4, where the point that does not move as `s` changes is
the pivot actually in use. Repeating that per display at teach time, and after a resolution change,
gives the constant a definition that survives both.

**Gates.** `out` (strip genuinely on screen) and the retract/departure thresholds are per group. The
80-point retract test and the 286.92 gutter figure were both measured on one display; a second strip
with a different tile count or a different gutter makes them hypotheses again.

**Transaction.** `apply_all()` creates the transaction from `cgid_main()`, the main CGS connection.
Whether a transform for a window hosted on another display can be committed through that connection, or
needs the display's own connection, is unverified; one tile at `s = 1.2` on the second display answers it.
Everything else in the apply path is per-window and would carry over unchanged.

**Refusal until then.** The issue asks for a loud refusal on a configuration known to be unsafe. Two
configurations are already known to be unhandled: more than one active display, and a main display
narrower than the flush threshold. Both can be checked in `doctor()` in `wmship/install.py` as a
`checks` entry and a `refusals` reason, which means `wmshipd` would also refuse to re-apply after a
display is plugged in while armed, rather than mis-scaling quietly. That is the right default until the
per-display work exists; it is the difference between a capability that stops and one that silently
scales about the wrong point.

## 6. Verified and unverified

Verified while writing this note:

| claim | how |
|---|---|
| The machine has exactly one active display: built-in, 3024×1964 at 2×, i.e. 1512×982 points. | `system_profiler SPDisplaysDataType`, `sw_vers` (macOS 27.0.1, build 26A434) |
| No code enumerates displays or reads a Space identifier. | search for `CGGetActiveDisplayList`, `NSScreen`, CGS display and Spaces APIs |
| The rail and flush tests are main-display x-interval tests, as listed in §2. | read of `helpers/r21obs.swift`, `wm/wmctl.py` `measure()`, `wmship/payload.c` |
| The pivot is one constant applied to every tile. | `G.qx`/`G.qy` defaults and `mat_scale()` |
| The natural-width record is keyed by window id and refreshed only when the id set changes. | `apply_scale()` in `wmship/ctl.py` |
| The stage model is read from one `sm.space` → one `sm.strip`. | `WM.stages()` in `a/stagepilot.swift` |

Unverified, and therefore not claimed:

- Whether a strip appears on a second display, and if so in which coordinate range.
- Whether `rail_now` would ever contain a second display's tiles, or whether the keeper is blind there.
- Whether tiles are per display or one strip follows the focused display.
- What a resolution change does to taught bases, to the pivot error, or to the resize verification.
- Whether a transform for a second display's window can be committed through the main CGS connection.
- Multi-Space behaviour, separate Spaces per display, and Stage Manager off/on while armed.

Until a row of the matrix is filled, the honest description of this area is "works on one display,
untested elsewhere", and the arm-time refusal in §5 is the only part of the design that can be written
without measuring.
