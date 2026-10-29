# Births for an already-running app — measured path and the anchor the fix needs

Issue: #36. Status: **investigation complete, no behaviour change.** This note records what was
measured tonight, why the current birth hook cannot cover the case, and the one structural anchor
that can. It is written for the next attempt, not as a substitute for one.

## What was reproduced

Machine: macOS 27.0.1, WindowManager 462.0.8.402, `pid 11184` for the whole session (no restart,
no crash). Helper and both observers running; no debugger in any armed trial.

Setup: TextEdit already running with a document, sitting in a non-current stage; Ghostty current.
Then, without activating TextEdit:

```sh
open -g -a TextEdit /tmp/birth.txt
```

Observer (`/tmp/wm/obs.log`), trial for `birth-sameapp3.txt`:

```
1793286132.328 NEW  wid=10030 owner=TextEdit pid=21996 on=0 0,0 0x0 name=birth-sameapp3.txt
1793286132.363 TILE wid=10030 owner=TextEdit dt=0.035 at 48,708 96x117
```

That is issue #36's signature exactly (the issue measured `48,713 96×117`). Counters after the
trial: `inject=0`, so the window stayed in TextEdit's offscreen stage. Repeated with TextEdit
having *no document windows at all* (its stage removed from the strip): same result, a tile at
`16,708 98×117`.

When TextEdit was the current app instead, a new document joined the current stage by itself
(`FULL`, 254,105 665×433) with one driver call and no injection. The failure is therefore specific
to the app not being the current stage — which is the case Sturgeon exists for.

## Why the current hook cannot see it

The birth hook is a substitution of `x0` at the two `bl driver` call sites (`birth`, `birth2`).
Instrumenting the birth path (the model register and the transient-operation buffer the caller is
building were dumped read-only, per call) across every same-app trial produced **zero calls at
either birth site**. The placement driver itself *was* entered — `drv` grew by tens of calls and
the birth branch ran — but only through its entry (`driverE`), i.e. from a caller that is not one
of the two patched `bl` sites, and always with an **empty** transient-operation array.

So the payload gets the birth branch at the right moments, and the branch does what it is designed
to do: it calls `identify()`, which defers because no young `CGWindowID` has been published yet
(`pdwait` 26 in one trial), then misses. The window server lists the new window tens of
milliseconds later; by then nothing calls the driver again. This is the measured cause, confirmed
from the inside rather than inferred from counters.

Two identity alternatives were tested at that entry and both fail:

* **The WM model (`x20`, `io_wids` census).** Scanning the model for WindowIDs the census can
  confirm, with a rendezvous at the call, found either nothing (`mn = 0`, 2 rendezvous in the
  trial) or an unrelated window. In one explicit A/B it picked the current front window (Ghostty,
  serial 102) and injected it into the current stage — a wrong-window injection that happened to
  be a no-op because the target was already there. It is not a newborn identity.
* **The CGWindowID path.** `fresh_candidate()`/`io_pd` is the window server's list, which is the
  thing that lags. No rearrangement of that data can make it hold a window it has not listed.

A third observation matters for the fix: the newborn is registered in the WM's own
`WindowIDTable` before the observer sees it. `WindowIDTable._map` is keyed by serial and its value
is `{ cgWindowID, stageID }`; during the trials the newborn's entry appeared with the stage it was
assigned (`cg=10061 ser=160 stage=37404`, TextEdit's stage; another trial allocated a *new* stage
id, `cg=10050 ser=158 stage=37450`). That table, not `CGWindowList`, is the WM's record of "this
window belongs to this stage".

## The anchor: the set assignment, not the placement driver

The entity that performs the assignment is reachable and its shape was measured this build
(per-build values below are evidence, not constants to compile in):

| what | value (build 462.0.8.402) |
|---|---|
| `StageManagerWindowSetModelComponent` class metadata | `0x1005b4698` |
| its `windowSetRegistry` stored-property offset | `0x4e0` (global at `0x1005b4640`) |
| registry dictionary storage | `*(component + 0x4e0)` |
| its vtable (27 immediate members) | class metadata `+0x68 … +0x120` |
| WM-resident vtable methods | `0x1002edf9c`, `0x1002eea90`, `0x1002ef9e8`, `0x1002efa38`, `0x1002f03e8/418/444/484` |
| `ModifyWindowSetRequest` struct descriptor | `0x1004d9abc`; cases `createUserWindowSet`, `addWindowToUserWindowSet`, `removeWindowFromUserWindowSet` (field records `0x10050868c/698/6a4`) |

Live probing of those methods during a same-app birth showed two of them running at the assignment
(`0x1002eea90`, which returns a model snapshot, and `0x1002efa38`, a component method receiving a
buffer that contains WindowID pointers), but did **not** pin a single function that takes
`(window, set)` and commits the assignment. The remaining work is therefore specific:

1. Instrument the component's vtable methods one at a time (a `b` to the island at the method
   entry, logging `x0…x4` and the first 0x200 bytes of the request buffer) during one same-app
   birth, and find the call that carries both the newborn's `WindowID` and a set identifier.
2. Redirect that call to the current stage's set — the same set the `move` path already targets —
   or, if the call builds a `ModifyWindowSetRequest`, substitute `addWindowToUserWindowSet` with the
   current set id.
3. Prove the two negatives in the same armed session: stage switching does not move windows it
   should not, and `move` still addresses the stage it names.

The WindowIDTable mutation itself is **not** the anchor: a write watchpoint on `table+0x20` lands
in a generic dictionary-update helper (`0x100112584`; the store is at `0x100112618`), which
increments `_serial` and rewrites `_map`. It records the stage value but does not choose it.

## Anchor B

`SLSRegisterNotifyProc`-class notification was not measured. Even if it fires for a same-app
window, it only supplies an event; the payload would still need to perform the assignment, and the
only assignment paths found are the component's modify path above or the placement driver, which
does not run after the window is visible. It is a source of *timing*, not of *action*, so it is not
a substitute for anchor A — at best it bounds when to try.

## Consequences for the shipped design

* `BIRTH_MAX_AGE`, `pdwait`, the "newest serial" and "same-poll tie" rules are all about picking a
  window out of `CGWindowList`. They cannot fix this case; do not extend them.
* A fix that depends on a driver call cannot cover the reproduced case at all.
* The window's own `WindowID` is available inside the WM at the assignment and in
  `WindowIDTable._map`; use that, and let the set assignment be the event.

## How to reproduce

```sh
# armed, helper + observers running
open -a TextEdit /tmp/base.txt          # give TextEdit a stage
sleep 3
open -a Ghostty                          # make another app current
sleep 1
open -g -a TextEdit /tmp/birth.txt       # same-app birth, not activated
tail -3 /tmp/wm/obs.log                  # NEW, then TILE at 48,708 96x117
```
