# Deriving the transform from a measured frame — verdict: not viable on this build

The keeper needs a tile's resting 4x4. Today it gets one by teaching: it hovers the strip, waits for
the WindowManager to stop writing, and keeps the pose it settled on. The question this note answers
is whether that teaching can be replaced by *deriving* the matrix from something already measured —
the tile's frame in `CGWindowList` (or the same frame in the state document), which needs no hover.

**Short answer: no.** The frame does not carry enough information to invert the pose, the pose's
translation is not in screen coordinates, and there is no event to calibrate against. Teaching stays.

## What is measurable, and what the numbers say

| quantity | where it comes from | value / behaviour |
|---|---|---|
| drawn frame of a tile | `CGWindowList` (`r21probe`) and the state document's `rail_now` bookkeeping | the frame the WindowServer composites — **it includes the hover lift**: the same tile reads `w=131` at rest and `w=139` while lifted |
| the pose the WM writes | the keeper hook (`m[16]`, first entry is the linear scale) | `m0` is **natural ÷ drawn**, so a lift is a *smaller* `m0` (1.883 at rest, 1.775 lifted), and the resting value is the largest `m0` a tile has |
| the pose's translation | `m[12]`, `m[13]` | **not screen coordinates.** Any absolute-x gate on a write refuses every write (round 34 measured `learn +0` over two full sweeps on a gate built on `m[12] >= 0`) |
| writes on a layout change | the keeper hook | **zero**: a 1 px window move writes nothing, and an idle strip writes nothing for 1.5 s |
| the retract | the keeper hook | a pure translation plus a rotation about the strip pivot: 286.92 px of leftward travel, `m0` unchanged |

Three consequences, in the order they kill the idea:

1. **The frame is the drawn frame, so it is only the resting frame when nothing hovers.** The strip
   is drawn while the pointer is near the left edge, which is exactly when a tile can be lifted.
   Measured, same capture: `w=131` at rest, `w=139` mid-hover. A derivation that samples the frame
   has to model the lift — a few percent, per tile, with unknown phase — which is the error the
   quiet-promotion rule exists to avoid.

2. **`drawn_w = natural_w / m0` has two unknowns and one equation.** The document carries no natural
   width for a tile; the accessibility tree carries the *layout* rect, not the natural width, and on
   this build it is a third number again (a tile whose drawn frame is 131 px wide has a pile frame
   of 217.7 px and an `m0` of 1.883). So even the scale entry cannot be inverted without teaching
   at least one of the three.

3. **The translation is in a different space than the frame.** `m[12]` is neither screen x nor a
   simple offset from it on this build, so a frame cannot give the matrix's last column at all. The
   measurement that settles it is the failed absolute gate above: if `m[12]` were screen x, a
   `m[12] >= 0` test would accept the resting pose.

## What *is* worth deriving

The pivot, and only the pivot. `mat_scale()` scales about a constant point `(16, 490)` — a point in
the strip gutter — and that constant is the one genuinely fragile number in the keeper: a different
display size or a moved strip scales about the wrong point, quietly. The strip's own rect is in the
document (`rail_x`, and the strip frame the observer reports), so the pivot can be expressed as a
function of that rect and checked against `(16, 490)` on this build before it replaces it. That is a
separate, smaller change, and it should be measured the same way the base was: hold the strip at a
known rect, scale 1.5, and compare per-tile geometry against the constant.

## What would change the verdict

A write the WM makes on a *layout* event would be a calibration event: teach once from the settle,
then, on every layout write, solve for the mapping between the frame the document reports and the
pose. This build does not produce one (idle and 1 px moves write nothing), and until it does, the
only trustworthy source of a resting pose is the pose stream itself.
