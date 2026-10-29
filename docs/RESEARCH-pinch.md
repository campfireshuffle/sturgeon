# Research: trackpad pinch-to-resize on the strip

Status: **parked**, pending one physical-gesture test. The transform path is proven; the input path is
not. Pinch cannot be synthesised on this build, but nobody has established whether a real pinch reaches
a third-party process at all, because no pinch was ever performed during the original work.

## 1. What the feature actually needs

Less than it appears. The keeper already composes the current scale onto every pose the WindowManager
emits, so a gesture does not need a new transform path, a new patch site or a new SkyLight call:

- `G.s` holds the scale; `apply_all()` and the keeper's write hook pass the taught base through
  `mat_scale(base, s, qx, qy, out)` and commit the result.
- `G.s` arrives from the config page. The page lives in the WindowManager's address space and is
  written over the task port, so whatever produces the gesture has to reach it through the same root
  path `ctl.py` uses. `resize` writes it once; a gesture helper would write it on every gesture frame.
- The whole chain was proven with a modifier + scroll trigger: 5/5 trials bigger at 1.493–1.500, 5/5
  smaller at 0.595–0.603, 5/5 controls at exactly 1.000, at 167–212 ms per step, with tiles inside the
  gutter, on screen, clickable at the new geometry.

So the only missing piece is a stream of scale deltas. That reframing matters for the decision in §4:
the hard part is not doing anything with a pinch, it is receiving one.

## 2. What was established

| question | result | basis |
|---|---|---|
| Is there a public way for a third-party process to create a magnification event? | No. IOKit on this build does not export `IOHIDEventCreateMagnificationEvent`. | symbol check on macOS 27.0.1 / 26A434, repeated for this note; see §2.1 |
| Can a generic HID scale event be constructed and dispatched instead? | Constructed: yes (`IOHIDEventCreateScaleEvent` is exported). Dispatched: refused, `0x540000` as root and `0x5040000` as an ordinary user, with no magnify `NSEvent` produced. | recorded during the original work; the same build family, not re-run here because dispatching injects input into the session |
| Does the strip accept any gesture? | No. It advertises no resize accessibility action and no drag handle, and its width is derived from tile content (150–255 points), not set by the user. Five phase-tagged gesture posts over the strip changed tile or strip geometry 0 times. | recorded during the original work |
| Can an app observe a pinch? | Not established. A global `NSEvent` monitor for `.magnify` installs and would receive it, but it was never fed a real pinch: automation cannot perform a physical gesture. | `helpers/r21gesture.swift`; never exercised |

### 2.1 The symbol check, reproducible

Which constructors the running IOKit exports is a one-file check, with no event posted:

```c
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    const char *n[] = {"IOHIDEventCreateMagnificationEvent", "IOHIDEventCreateScaleEvent",
                       "IOHIDEventCreateZoomToggleEvent", "IOHIDEventCreateScrollEvent",
                       "IOHIDEventSystemClientCreate", "IOHIDEventSystemClientDispatchEvent",
                       "IOHIDEventSystemClientCreateWithType"};
    for (unsigned i = 0; i < 7; i++) printf("%-42s %s\n", n[i], dlsym(h, n[i]) ? "exported" : "absent");
    return 0;
}
```

Result on macOS 27.0.1 (26A434), arm64, with `clang -o hidsyms hidsyms.c && ./hidsyms`:
`IOHIDEventCreateMagnificationEvent` **absent**; the other six **exported**. The absence has been
checked more than once, on the same build family, with the same result; it is the reason the synthetic
route starts with a scale event rather than with a magnification event.

## 3. The four routes

| route | in one line | status |
|---|---|---|
| A. Synthetic magnification event | create and dispatch a gesture event from our process | closed on this build: no constructor, and the scale-event proxy is refused |
| B. Read the trackpad's stream and apply the transform ourselves | observe the gesture, write `cfg.s`, let the keeper do the rest | **open**: architecture proven, input unverified |
| C. Intercept a gesture macOS already reports, before the WindowManager | be upstream of the WM's recogniser and consume the event | closed by API shape as stated |
| D. Accept that resize is a UI control | keep the slider and `wmship.sh resize` | the fallback, not yet chosen |

### A. A synthetic magnification event

Two variants. The direct one needs `IOHIDEventCreateMagnificationEvent`; it does not exist on this
build, so there is nothing to call. The proxy is an axis scale event (`IOHIDEventCreateScaleEvent`,
type 7) dispatched through `IOHIDEventSystemClientDispatchEvent`; that is refused even as root, and no
`NSEvent` appears at the receiving end.

What would have to be true for it to work: a build that exports a magnification constructor, or a
dispatch path that the input system accepts from a non-Apple process; and the delivered event would
still have to reach *our* process, not only the WindowManager, because we are the ones applying the
scale. A future macOS could change this, so the check is worth repeating after a major update, but it is
not a route we can build on today.

### B. Read the trackpad's scale stream and apply the transform ourselves

This is the route the architecture is already shaped for: a helper observes the gesture, writes a new
`gen` and `s` into the config page, and the keeper applies it on the next pose write. Nothing is
synthesised, so no entitlement or dispatch permission is needed for the event itself.

What would have to be true:

1. A two-finger pinch is delivered to a process that is not frontmost. The registered monitor is
   process-wide and passive; whether the WindowManager consumes the gesture first when the pointer is
   over the strip has never been tested.
2. The event carries a usable delta. `NSEvent.magnification` is a per-event increment, which multiplies
   cleanly; a HID-level reader would instead see raw scale fields and would need its own delta handling.
3. If the app-level monitor is refused or never fires, an `IOHIDEventSystemClient` monitor for the
   trackpad's service can be created and scheduled without a private entitlement, or a root helper can
   hold it. Neither has been attempted.
4. The delivery rate is adequate, and the config path can carry it. `cfg_set()` in `wmship/ctl.py` is a
   read-modify-write of the whole configuration followed by a 300 ms sleep, so it caps a trigger at
   about three updates per second. A gesture-driven scale would need a lighter write: only `s` and a
   generation that cannot repeat, with no settle. The keeper already applies `s` on the next pose
   write, so the WindowManager is not interrupted for this, but the feel of a stepped scale has not
   been measured.
5. The gesture is gated to the strip. A global monitor sees every pinch in every application, so the
   helper has to check the pointer against the strip's rectangle before changing `s`, and the existing
   clamp of 0.4–1.5 (and the gutter cap) still applies.

The first item is the one that decides the feature, and it costs one physical pinch to answer.

### C. Intercept a gesture macOS already reports, before the WindowManager

The idea is to sit upstream of the WM's gesture recogniser and take the pinch before it is acted on.

What would have to be true: gesture events pass through a layer an ordinary process can tap and
consume, and the WM's recognition is downstream of that layer. Neither holds as stated. A `CGEventTap`
sees `CGEvent`s, and magnification is not a `CGEvent` type; a global `NSEvent` monitor observes and
cannot modify or consume; a local monitor only sees events delivered to its own application. The only
place genuinely upstream of the WM's recogniser is inside the WM, which is where the payload already
runs, but the payload has no timers, no file I/O, no Objective-C dispatch, and acts only when patched
code runs. Adding a site on a hypothetical magnify handler would need a new locator signature and
evidence that such a handler exists; the strip exposes no resize affordance, so there is no reason to
think it does.

This route is therefore not a smaller version of B; it is a larger one with a worse evidence base.

### D. Accept that resize is a UI control

The honest fallback: keep the slider and `wmship.sh resize`, and say in `docs/TECHNICAL.md` that pinch
is not available on this build. This is what the documentation says today, and it stays true until §5
is run.

## 4. Decision: park

Park, not close, and not pursue.

- Not pursue: route A is refused on this build, route C is closed by API shape, and route B's remaining
  unknown is not a design question but a single observation that nobody has made.
- Not close: closing would assert that a real pinch never reaches a monitor, which has not been
  measured. The transform path is proven and the receiver is a few lines; if a pinch does arrive, the
  feature is small.
- Park: the cost of settling it is one physical gesture and about ten minutes, and the result changes
  the answer completely in either direction.

The decision rule: if a real pinch produces no `.magnify` callback on any of the three surfaces in §5,
close this as not doable on this build, keep the UI control, and record the negative in
`docs/TECHNICAL.md` so it is not re-litigated. If it produces one, implement route B and measure it.

## 5. The smallest experiment that settles it

One person, one trackpad, no root, no arming, no patch. The receiver already exists in
`helpers/r21gesture.swift`, which installs a global `.magnify` monitor and logs each event with the
resulting scale.

1. Build the helper against a scratch output so nothing else reads its config. Its log path is fixed at
   `/tmp/r21/gesture.log`, so create that directory first:

   ```sh
   mkdir -p /tmp/r21
   swiftc -O -target arm64-apple-macos14.0 -o /tmp/pinchprobe helpers/r21gesture.swift
   /tmp/pinchprobe --out /tmp/pinchprobe-cfg.json
   ```

2. Confirm `/tmp/r21/gesture.log` contains `magnify monitor installed`. A nil monitor (`NO magnify
   global monitor`) means the monitor was refused. A non-nil monitor that never fires can also mean the
   process lacks accessibility trust, so check the permission either way before drawing a conclusion;
   silence alone does not prove the event does not exist.

3. Perform one physical two-finger pinch, about a second, on each of three surfaces, in this order:
   - over the revealed strip, with the pointer on a tile;
   - over an ordinary application window;
   - over the desktop with no window focused.

4. Pass condition: a `pinch s=… gen=…` line appears in the log for a surface. Record the magnification
   value and whether the log shows one line or a run of them; one line means the gesture was delivered
   once at the end, a run means it can drive a live scale.

5. If it passes, the one remaining question is the case that matters: does the callback still arrive
   when `WindowManager` is frontmost and the pointer is over the strip? If yes, feed the scale into the
   payload through the path `ctl.py` already uses (`I.write_cfg` over the task port), with a lighter
   write than `cfg_set()` and a generation that cannot repeat; gate on the pointer being inside the
   strip rectangle; and measure latency at `s = 1.0 → 1.2` against the 167–212 ms figure for the
   interrupt-based trigger.

6. If it fails on all three surfaces, the app-level path is closed. A second, larger experiment remains
   available: create an `IOHIDEventSystemClient` of the monitoring type, register an input-value
   callback for the trackpad's service, and see whether scale fields arrive at all. That test needs
   either root or a private entitlement, and its outcome is unknown; it should not be attempted until
   the app-level test has failed, because it costs far more and answers the same question one layer
   lower.

What this experiment does not settle: whether a pinch arriving while another application is frontmost
is still delivered (step 5), whether the scale feels continuous rather than stepped, and whether the
WindowManager's own gesture handling interferes with a pinch that begins over a tile.

## 6. Verified and unverified

Verified while writing this note:

| claim | how |
|---|---|
| macOS 27.0.1 (26A434) on arm64 exports `IOHIDEventCreateScaleEvent`, `IOHIDEventCreateZoomToggleEvent`, `IOHIDEventCreateScrollEvent`, `IOHIDEventSystemClientCreate`, `IOHIDEventSystemClientDispatchEvent` and `IOHIDEventSystemClientCreateWithType`, and does not export `IOHIDEventCreateMagnificationEvent`. | `dlsym` on IOKit, §2.1 |
| The keeper applies the current scale on every pose write, and `s` comes from the config page. | `apply_all()`, `mat_scale()`, `read_cfg()` in `wmship/payload.c` |
| A gesture helper is already wired to write `s` and a new generation, and it installs a global `.magnify` monitor. | `helpers/r21gesture.swift` |
| The transform path scales tiles correctly under a non-gesture trigger. | recorded trials, 5/5 bigger, 5/5 smaller, 5/5 controls |

Recorded during the original work, not re-run for this note:

- `IOHIDEventCreateScaleEvent` dispatch returns `0x540000` as root and `0x5040000` as user, and no
  magnify `NSEvent` is produced. Re-running it would inject an input event into the session, so it was
  deliberately not repeated.
- Five phase-tagged gesture posts over the strip changed geometry 0 times; the strip exposes no resize
  accessibility action and no drag handle, and its width follows its tiles.

Unverified, and therefore not claimed:

- Whether a real trackpad pinch reaches a global `NSEvent` monitor on this build, in any application.
- Whether such a callback arrives when `WindowManager` is frontmost and the pointer is over the strip.
- Whether an `IOHIDEventSystemClient` monitor can read the trackpad's scale stream without a private
  entitlement.
- The latency, continuity and feel of a gesture-driven scale.
