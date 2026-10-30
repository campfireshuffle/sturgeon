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
trial: `place=0`, so the window stayed in TextEdit's offscreen stage. Repeated with TextEdit
having *no document windows at all* (its stage removed from the strip): same result, a tile at
`16,708 98×117`.

When TextEdit was the current app instead, a new document joined the current stage by itself
(`FULL`, 254,105 665×433) with one driver call and no placements. The failure is therefore specific
to the app not being the current stage — which is the case Sturgeon exists for.

## Why the current hook cannot see it

The birth hook is a substitution of `x0` at the two `bl driver` call sites (`birth`, `birth2`).
Instrumenting the birth path (the model register and the transient-operation buffer the caller is
building were dumped read-only, per call) across every same-app trial produced **zero calls at
either birth site**. The placement driver itself *was* entered — `drv` grew by tens of calls and
the birth branch ran — but only through its entry (`driverE`), i.e. from a caller that is not one
of the two patched `bl` sites, and always with an **empty** transient-operation array.

So the component gets the birth branch at the right moments, and the branch does what it is designed
to do: it calls `identify()`, which defers because no young `CGWindowID` has been published yet
(`pdwait` 26 in one trial), then misses. The window server lists the new window tens of
milliseconds later; by then nothing calls the driver again. This is the measured cause, confirmed
from the inside rather than inferred from counters.

Two identity alternatives were tested at that entry and both fail:

* **The WM model (`x20`, `io_wids` census).** Scanning the model for WindowIDs the census can
  confirm, with a rendezvous at the call, found either nothing (`mn = 0`, 2 rendezvous in the
  trial) or an unrelated window. In one explicit A/B it picked the current front window (Ghostty,
  serial 102) and placed it into the current stage — a wrong-window placements that happened to
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
window, it only supplies an event; the component would still need to perform the assignment, and the
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
tail -3 /tmp/wm/obs.log                  # NEW, then TILE at 48,708 96x117
```

---

## Round 37 addendum — the table's second field is a pid, and the component is not on the birth path

Status: **still no behaviour change.** This addendum corrects one fact the section above relies on,
records what the set-model component actually does during a same-app birth, and leaves the commit
unpinned with a named next step. Instrumentation was live on the owner's machine; the transcript is
below, including two WindowManager watchdog kills caused by the debugger (not by the payload).

### 1. Correction: `WindowIDTable._map` carries the owner *process*, not the stage

The section above says the map value is `{ cgWindowID, stageID }` and that "the newborn's entry
appeared with the stage it was assigned (`cg=10061 ser=160 stage=37404`)". The second `u32` is the
**owner pid**. Measured on build 462.0.8.402 by reading the live map and correlating it with the
observer's `NEW` lines (`/tmp/wm/obs.log`, which prints the pid):

| map entry | observer line |
|---|---|
| `key=124 cg=10124 pid=86236` | `NEW wid=10124 owner=TextEdit pid=86236` |
| `key=93 cg=10169 pid=87707` | `NEW wid=10169 owner=Open and Save Panel Service pid=87707` |
| `key=2 cg=9547 pid=94163` | `NEW wid=9547 owner=Orca pid=94163` |
| `key=37 cg=9740 pid=17345` | `NEW wid=9740 owner=r20win pid=17345` |
| `key=72 cg=8258 pid=1499` | Dia, `pgrep -x Dia` = 1499 |

5 of 5 match, and the value's `String` at `+0x08` is the owner name (`profile.json` already says
`owner String@8, title@0x18`). It follows that the earlier trial's `stage=37404` was TextEdit's
**pid** — the same trial's observer line is `NEW wid=10061 owner=TextEdit pid=37404` — and
`37450` was the pid TextEdit was relaunched under. The table is the WM's
`WindowID serial → (cgWindowID, owner pid, owner, title)` index. It does not record a stage, so it
cannot be read as evidence of "the set the WM assigned". `wmship/profile.json`'s
`layout.map_value` and the comment above `publish_widcg()` still say `stageID`; this note is the
correction until that data string is fixed.

### 2. What the set-model component does during a same-app birth: nothing

Class metadata `0x1005b4698` (this build), slide `0x4840000`. The vtable at `class+0x68` is 27
entries; **slots 1–4 are the only resident methods** and slots 5–26 are
`_swift_deletedMethodError`:

| slot | file VA | what it is |
|---|---|---|
| 1 | `0x1002edf9c` | update, `void (InputModel)`, self in `x20`, input in `x0` |
| 2 | `0x1002eea90` | model snapshot getter |
| 3 | `0x1002ef9e8` | returns the 24-byte registry triple |
| 4 | `0x1002efa38` | returns one 8-byte word |

The four functions the earlier note counted as "8 WM-resident methods" (`0x1002f03e8/418/444/484`)
are **protocol witness thunks** that forward to slots 3, 4, 1 and 2 respectively, with an indirect
return buffer in `x8` (the 33-byte input copy at `0x1002f0444` is visible in the disassembly). They
are not vtable slots.

Eight breakpoints (the four methods plus the four thunks), each logging `x0…x4/x8/x20/lr/pc` and
continuing, over a four-minute window on pid 11184 that included a TextEdit launch (11:43:53):

```
m1 0x1002edf9c  hits 0
m2 0x1002eea90  hits 2   (11:47:30.204, 11:48:01.893)
m3 0x1002ef9e8  hits 0
m4 0x1002efa38  hits 0
t5..t8          hits 0
```

Both m2 hits have `x20 = 0x7957745900` (the live component, the only one of six `isa` hits that
validates), `x0 = 0x16b5a14f0 = self + 0x10` (the component's inline `inputModel`),
`x8 = 0x42d0` (`StageManagerSpaceComponent.windowSetModelComponent`), `lr = 0x1002ae768`. They are
**not birth hits**: the nearest `NEW` line in the observer log is 4.2 s before the first and 7.3 s
after the second, and the two hits are 31.7 s apart — a periodic model read, not a window event.
During the same window `StageManagerWindowSetModelComponent`'s update (slot 1, the only code that
installs a registry) never ran.

So the anchor this note proposed is not on the birth path on this build. The `(WindowID, set)` commit
was **not** pinned.

### 3. New: the WM's own registration *is* synchronous with a same-app birth

The failure reproduced twice on this machine before any instrumentation, with the same signature as
the section above (`open -g -a TextEdit` while TextEdit's stage was not current):

```
1793289264.185 NEW  wid=10209 owner=TextEdit pid=86236 on=0 0,0 0x0 name=r37birth1.txt
1793289264.350 TILE wid=10209 owner=TextEdit dt=0.165 at 31,224 98x111
1793289479.838 NEW  wid=10210 owner=TextEdit pid=86236 on=0 0,0 0x0 name=r37birth2.txt
1793289479.866 TILE wid=10210 owner=TextEdit dt=0.030 at 48,224 96x111
```

`wmship/wmhb --verify` (task port, no debugger) before and after one same-app birth while TextEdit
sat in a non-current stage:

```
before  {"objects":143,"serials":143,"map_entries":134,"map_matched":134}
birth   open -g -a TextEdit /tmp/r37birth3.txt      -> TILE at 48,224 96x111
after   {"objects":144,"serials":144,"map_entries":135,"map_matched":134}
```

Exactly one new `WindowID` object, one new serial and one new map entry per same-app birth, at the
moment of the birth — while the user-side window list has not published the window yet
(`map_matched` stays at 134). That is the event the driver hook never had.

### 4. Where the next attempt should start

The registration path is the only site measured to run exactly once per same-app birth:

| item | value |
|---|---|
| serial bump + placeholder insert | `0x1001127d8` (increments `table+0x18`, copies the map at `table+0x20`, inserts a zeroed `(cg=0, pid=0, "", "")` value) |
| its callers | `0x100290e10` (window-set model / space update) and `0x1003d89cc` (window ordering, the function that also takes the table lock at `0x1003d8e68`) |
| table instance | global `0x1005a35e8`; class metadata `0x1005a34b0` |

An attempt should hook `0x1001127d8` (or the ordering caller) **in the payload**, not in a debugger:
one branch is cheap and in-line, and the payload already owns the control page. The open question
that decides whether a fix is possible is still the same one: which code, after registration, chooses
the set — and that is what a hook on `0x1001127d8` returning the caller is meant to answer.

### 5. Instrumentation transcript (machine events)

| time | event |
|---|---|
| 11:38 | lldb attached to pid 11184, slide `0x4840000`; vtable read; `isa` scan found the component |
| 11:41 | eight breakpoints, each running a Python `hit()` that read six 256-byte buffers per hit |
| 11:48:24 | **WindowManager 11184 died** — no crash report, i.e. the watchdog; lldb exited with it; launchd restarted it as 87619 |
| 11:57 | pid 87619, slide `0x4a0000`; hardware watchpoint on `table+0x18`; a birth produced its tile in 28 ms and the watchpoint did not fire |
| 12:05 | **WindowManager 87619 died** — again no crash report; restarted as 5976 |
| 12:07 | final measurement used `wmhb --verify` only (no debugger) |

Both kills are the debugger's stop time, not the payload's: the payload was never armed in this
session. The previous watchdog kill in this project had the same cause. **Do not instrument this
process with a command that reads memory on every hit, and do not set more than one stop of any
kind at a time.**

---

## Round 38 — the registration anchor: correct site, unsafe submission, and no newborn identity

Status: **negative result; the line is stopped.** No behaviour change is shipped. This section
records the correct registration call (the round-37 addendum hooked the wrong function), the
implementation that was tried, the two measurements that ended it, and the WindowManager death
that makes a retry without a new safety mechanism irresponsible.

### The round-37 anchor was the *mint*, not the registration

`0x1001127d8` is `WindowIDTable.next()`: it bumps `_serial` at `table+0x18` and inserts a
**placeholder** value `(0,0,"","")` at `table+0x20`. Its two callers are the strip-pile padding loop
(`0x100290e10`, which uses the serial to build an empty tile model) and the XPC record path
(`0x1003d89cc`). It runs for every minted WindowID, including placeholders that never become a
window, so it is not a birth event by itself.

The call that writes the identity is `sub_100112e9c`, reached from **one** place in `__TEXT`:

```
0x1003d8f84  ldr  x8, [x19, #0x90]       ; the WindowID this record is about
0x1003d8f88  ldr  x0, [x8, #0x10]        ; its serial
0x1003d8f8c  and  x2, x24, #0xffffffffff ; CGWindowID
0x1003d8f90  orr  x3, x28, x26           ; owner pid (+ a flag in bit 32)
0x1003d8f94  ldr  x4, [x19, #0x8]        ; owner String
0x1003d8f98  mov  x5, x27
0x1003d8f9c  mov  x6, x23                ; title String
0x1003d8fa0  mov  x7, x20
0x1003d8fa4  bl   sub_100112e9c
```

`sub_100112e9c` takes the table lock, ensures the value array is unique, and stores
`cgWindowID` at value+0, `ownerPID` at +4, the owner at +8 and the title at +0x18. That is the table
row the rest of the system sees; it is the only registration in `__TEXT` with this shape, and the
callee has exactly one `bl` caller. Hopper's caller/cross-reference analysis and an offline
`wmlocate.py` pattern search agree on `0x1003d8fa4`.

### What was built (not shipped)

Seven-site resolution: the site was added to `wmlocate.py` as `reg` (the eight-word setup above,
callee prologue and single-caller checks), to `install.py` as a one-call "blpost" stub, and to the
payload as `p_reg`. The island stub replays the original `bl`, then calls the payload with the saved
arguments and the caller's `x19`; the payload validates that `[x19+0x90]` is a live WindowID whose
serial is the registered serial, filters owner pid / owner string / process age, and records one
pending WindowID. `drv_body` claims it at the next driver call carrying an empty operation array —
the same one-element operation `move` submits — and submits it to the current stage.

The process-age filter (`wmhb` publishes app pid start times) was meant to leave launches to the
existing driver path, so a multi-document launch could not have a restored document moved instead of
the requested one. The debugger-free unit tests for the filter and the claim (31 cases) passed.

### Measurement 1 — observation only: the birth record was not accepted

Armed on WindowManager `5976` with the seven sites patched and `regbirth:false` (the hook records,
does not submit). One same-app birth (`open -g -a TextEdit /tmp/reg/b1.txt`) survived:

```
NEW wid=10491 owner=TextEdit pid=71128 ... name=b1.txt
TILE wid=10491 owner=TextEdit dt=0.029 at 31,385 98x98
```

Counters after the trial: `reg=184 regok=0 regold=135 regrej=49 reglaunch=0 regmem=0`. The site
fires (184 registrations), but **not one record was accepted**, including the newborn's. The birth
still became a tile. So the registration call as written cannot identify the newborn: either the
record that carries the new window is rejected by the serial/object check, or the same-app birth
does not use this call at all. Either way the anchor does not solve #36, even before submission.

### Measurement 2 — the first submission took WindowManager down

The payload was reinstalled (same WindowManager pid, seven sites patched, daemon load failed but the
helper was started manually) and the next same-app birth was issued with `regbirth:true`:

```
12:39:52.238  NEW wid=10492 owner=TextEdit pid=71128 name=b2.txt
12:39:52.408  WindowManager[74526] started        <- 5976 was gone
```

No WindowManager crash report was written (the same signature as the two round-37 watchdog kills),
the patch was gone, and `wmship.sh status` reported `DISARMED ... stopped pid=5976`. Two candidate
points fit the evidence: (a) the claim returned the synthesized operation array at a driver call
that was still inside the window-creation transaction, and the process deadlocked; or (b) the
recording path itself hung on this record. Measurement 1 shows the recording path had already run
184 times without harm, which points at the submission, but that is an inference, not a measurement.

### Restored state and what not to do

Immediately after the restart:

```
./wmship.sh stop        -> "WindowManager restarted (pid 74526 != 5976): nothing to restore"
./wmship.sh pristine    -> PRISTINE: yes (every site byte-exact)
no /tmp/wmship/state.json, no /Library/LaunchDaemons/com.stagemgr.wmshipd.plist,
no wmhb/wmobs/r21obs, no lldb
```

**This line is stopped.** Do not re-arm the registration hook to retry it. A next attempt needs two
things this round did not have:

1. **A positive identity measurement** at the registration call: the record that runs for a
   same-app birth must be shown, with counters or a surviving out-of-process log, to pass the
   serial/object check. Measurement 1 says the filter as written rejects every record; do not build
   the submission on top of an identity that has not been observed as accepted.
2. **A safe submission context.** The claim must not return an operation array from a driver call
   that may be part of the same creation transaction. Either prove the call's caller is a UI/state
   event, or find a submission path that does not re-enter the placement driver (the failure mode is
   a deadlock, which leaves no crash report and costs a WindowManager).

The facts worth keeping from this round: the table row is `(cgWindowID, ownerPID, owner, title)`;
`0x1001127d8` is the mint and is shared with the strip padding; the real registration call is
`0x1003d8fa4 -> sub_100112e9c` and it is unique; and the birth hook still cannot cover a same-app
birth.

### Reproduction (do not run armed without the two preconditions above)

```sh
cd /Users/sarimabbas/Developer/sturgeon-wt/reg
# nothing is committed for this attempt; the diff was kept out of the tree
./wmship.sh start                      # seven sites, WM pid must not change
./wmship.sh cfg '{"regbirth":false}'   # observation only
open -a TextEdit /tmp/base.txt; sleep 3
open -a <another app>; sleep 2
open -g -a TextEdit /tmp/birth.txt
./wmship.sh status                     # reg/regok/regold in the counters line
```

If `regok` is still 0 for the birth, the anchor is wrong for this build's same-app path; stop before
submitting. If a submission is ever tried, watch `/tmp/wmship/state.json` and `pgrep -f WindowManager`
for the pid change, and restore with `stop` + `pristine` immediately.
